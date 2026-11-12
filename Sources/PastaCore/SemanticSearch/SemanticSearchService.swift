import Foundation

public extension Notification.Name {
    /// Posted after semantic search settings or the API key change.
    static let semanticSearchConfigurationDidChange = Notification.Name("pasta.semanticSearchConfigurationDidChange")
}

/// Opt-in semantic search over clipboard history.
///
/// Keeps a vector per primary entry in `semantic_embeddings`, mirrors them in
/// an in-memory matrix, and answers queries by cosine similarity. Indexing
/// runs in the background, newest entries first, and pauses on errors.
public actor SemanticSearchService {
    public typealias EmbedderFactory = @Sendable (SemanticSearchConfiguration, String?) -> any TextEmbedding

    public struct Status: Sendable, Equatable {
        public var isActive = false
        public var isIndexing = false
        public var counts = SemanticIndexCounts()
        public var lastError: String?
        /// When set, indexing waits for this time before trying again.
        public var retryAt: Date?

        public init() {}
    }

    public struct Hit: Sendable, Equatable {
        public let id: UUID
        public let score: Float
    }

    static let indexingBatchSize = 32
    static let retryDelay: TimeInterval = 60
    static let queryCacheLimit = 64
    /// Relevant hits fetched before the caller's filters are applied.
    static let filteredCandidateLimit = 100

    private let database: DatabaseManager
    private let defaults: UserDefaults
    private let keyProvider: @Sendable (EmbeddingProviderKind) -> String?
    private let embedderFactory: EmbedderFactory

    private var configuration = SemanticSearchConfiguration()
    private var embedder: (any TextEmbedding)?
    private var index = SemanticVectorIndex()
    private var loadedIndexKey: String?
    private var status = Status()
    private var indexingTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var needsAnotherPass = false
    /// Identifies the current indexing worker, so a cancelled worker that
    /// resumes late cannot clear or pause its replacement.
    private var indexingGeneration = 0
    /// Set after an error that only a settings change can fix.
    private var isPausedForConfiguration = false
    /// In-flight query embeddings, cancelled when settings change.
    private var queryOperations: [UUID: Task<[[Float]], Error>] = [:]
    private var queryCache: [String: [Float]] = [:]
    private var queryCacheOrder: [String] = []

    public init(
        database: DatabaseManager,
        defaults: UserDefaults = .standard,
        keyProvider: @escaping @Sendable (EmbeddingProviderKind) -> String? = { try? SemanticSearchKeychain.read(provider: $0) },
        embedderFactory: @escaping EmbedderFactory = { RemoteEmbeddingClient(configuration: $0, apiKey: $1) }
    ) {
        self.database = database
        self.defaults = defaults
        self.keyProvider = keyProvider
        self.embedderFactory = embedderFactory
    }

    public var isActive: Bool { embedder != nil }

    public func currentStatus() -> Status {
        status
    }

    /// Re-reads settings and the API key. Starts, stops or re-targets
    /// indexing to match.
    public func reloadConfiguration() {
        let loaded = SemanticSearchConfiguration.load(defaults: defaults)
        let apiKey = keyProvider(loaded.provider)
        let active = loaded.isActive(apiKey: apiKey, defaults: defaults)
        configuration = loaded
        retryTask?.cancel()
        retryTask = nil
        isPausedForConfiguration = false
        cancelQueryOperations()
        status.retryAt = nil
        status.lastError = nil

        guard active else {
            embedder = nil
            indexingTask?.cancel()
            indexingTask = nil
            index.removeAll()
            loadedIndexKey = nil
            clearQueryCache()
            status = Status()
            return
        }

        embedder = embedderFactory(loaded, apiKey)
        status.isActive = true
        if loadedIndexKey != loaded.indexKey {
            indexingTask?.cancel()
            indexingTask = nil
            clearQueryCache()
            do {
                try database.deleteSemanticEmbeddings(notMatching: loaded.indexKey)
                loadIndex(indexKey: loaded.indexKey)
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.search, context: "Failed to prepare semantic index")
                status.lastError = error.localizedDescription
            }
        }
        refreshCounts()
        scheduleIndexing()
    }

    /// Embeds any entries missing from the index. Safe to call often.
    public func scheduleIndexing() {
        guard embedder != nil, retryTask == nil, !isPausedForConfiguration else { return }
        if indexingTask != nil {
            needsAnotherPass = true
            return
        }
        status.isIndexing = true
        indexingGeneration += 1
        let generation = indexingGeneration
        indexingTask = Task { [weak self] in
            await self?.runIndexing(generation: generation)
        }
    }

    /// Discards every stored vector and indexes the history again.
    public func rebuildIndex() {
        indexingTask?.cancel()
        indexingTask = nil
        retryTask?.cancel()
        retryTask = nil
        do {
            try database.deleteAllSemanticEmbeddings()
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.search, context: "Failed to clear semantic index")
        }
        index.removeAll()
        loadedIndexKey = nil
        clearQueryCache()
        reloadConfiguration()
    }

    /// Entries most similar in meaning to `query`, best first. Empty when
    /// semantic search is off or the provider cannot be reached.
    public func search(query: String, limit: Int) async -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0, let embedder, index.count > 0 else { return [] }
        let indexKey = configuration.indexKey
        let cacheKey = "\(indexKey)\u{1F}\(trimmed.lowercased())"

        let queryVector: [Float]
        if let cached = queryCache[cacheKey] {
            queryVector = cached
        } else {
            let operationID = UUID()
            let operation = Task { try await embedder.embed([trimmed]) }
            queryOperations[operationID] = operation
            defer { queryOperations[operationID] = nil }
            do {
                let vectors = try await withTaskCancellationHandler {
                    try await operation.value
                } onCancel: {
                    operation.cancel()
                }
                guard let vector = vectors.first else { return [] }
                queryVector = vector
            } catch is CancellationError {
                return []
            } catch {
                guard !operation.isCancelled else { return [] }
                PastaLogger.logError(error, logger: PastaLogger.search, context: "Semantic query embedding failed")
                return []
            }
            guard !operation.isCancelled, self.embedder != nil, configuration.indexKey == indexKey else { return [] }
            cacheQuery(cacheKey, vector: queryVector)
        }
        guard !Task.isCancelled else { return [] }
        return Self.relevantHits(index.search(queryVector, limit: max(limit * 4, 100)), limit: limit)
    }

    /// Like `search`, hydrated into entries that pass `isIncluded` (the
    /// caller's active filters). Entries deleted since they were indexed are
    /// dropped.
    public func searchEntries(
        query: String,
        limit: Int,
        where isIncluded: @Sendable (ClipboardEntry) -> Bool = { _ in true }
    ) async -> [ClipboardEntry] {
        let hits = await search(query: query, limit: Self.filteredCandidateLimit)
        guard !hits.isEmpty, !Task.isCancelled else { return [] }
        let entries = (try? database.fetchEntries(ids: hits.map(\.id))) ?? []
        return Array(entries.lazy.filter(isIncluded).prefix(limit))
    }

    /// Calls the provider once to prove the endpoint, model and key work.
    /// Returns the vector size.
    public static func testConnection(configuration: SemanticSearchConfiguration, apiKey: String?, session: URLSession = .shared) async throws -> Int {
        let client = RemoteEmbeddingClient(configuration: configuration, apiKey: apiKey, session: session, retryPolicy: .none)
        guard let vector = try await client.embed(["Pasta semantic search connection test"]).first else {
            throw SemanticSearchError.invalidResponse("no embedding returned.")
        }
        return vector.count
    }

    // MARK: - Relevance

    /// Keeps hits that stand out from the rest of the candidates. Embedding
    /// models differ widely in absolute cosine scores, so the cut-off is
    /// relative: close to the best hit and clearly above the typical score.
    static func relevantHits(_ hits: [SemanticVectorIndex.Hit], limit: Int) -> [Hit] {
        guard let best = hits.first?.score, best > 0 else { return [] }
        let scores = hits.map(\.score)
        let mean = scores.reduce(0, +) / Float(scores.count)
        let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(scores.count)
        let spread = variance.squareRoot()
        let floor = min(best, max(mean + spread, best - max(spread * 3, 0.05)))
        return hits.prefix { $0.score >= floor }.prefix(limit).map { Hit(id: $0.id, score: $0.score) }
    }

    // MARK: - Indexing

    private func runIndexing(generation: Int) async {
        defer {
            if generation == indexingGeneration {
                indexingTask = nil
                status.isIndexing = false
            }
        }
        repeat {
            needsAnotherPass = false
            while !Task.isCancelled {
                guard let embedder else { return }
                let configuration = self.configuration
                let indexKey = configuration.indexKey
                let candidates: [SemanticEmbeddingCandidate]
                do {
                    candidates = try database.pendingSemanticCandidates(indexKey: indexKey, limit: Self.indexingBatchSize)
                } catch {
                    pause(after: error, generation: generation)
                    return
                }
                guard !candidates.isEmpty else { break }

                var records: [SemanticEmbeddingRecord] = []
                var toEmbed: [(candidate: SemanticEmbeddingCandidate, text: String)] = []
                for candidate in candidates {
                    if let text = Self.documentText(for: candidate, configuration: configuration) {
                        toEmbed.append((candidate, text))
                    } else {
                        records.append(SemanticEmbeddingRecord(candidate: candidate, vector: nil))
                    }
                }

                var vectors: [[Float]] = []
                if !toEmbed.isEmpty {
                    do {
                        vectors = try await embedder.embed(toEmbed.map(\.text))
                    } catch is CancellationError {
                        return
                    } catch {
                        pause(after: error, generation: generation)
                        return
                    }
                    guard vectors.count == toEmbed.count else {
                        pause(after: SemanticSearchError.invalidResponse("wrong number of embeddings."), generation: generation)
                        return
                    }
                }
                guard !Task.isCancelled, self.configuration.indexKey == indexKey else { return }

                for (item, vector) in zip(toEmbed, vectors) {
                    records.append(SemanticEmbeddingRecord(candidate: item.candidate, vector: vector))
                }
                let written: Int
                do {
                    written = try database.saveSemanticEmbeddings(records, indexKey: indexKey)
                } catch {
                    pause(after: error, generation: generation)
                    return
                }
                for record in records {
                    if let vector = record.vector {
                        index.upsert(id: record.id, vector: vector)
                    } else {
                        index.remove(id: record.id)
                    }
                }
                status.lastError = nil
                refreshCounts()
                // Every candidate vanished before it could be stored; stop
                // rather than re-embed the same rows forever.
                if written == 0 { break }
            }
        } while needsAnotherPass && !Task.isCancelled

        guard !Task.isCancelled, generation == indexingGeneration else { return }
        refreshCounts()
        if status.counts.indexed != index.count, let key = loadedIndexKey {
            loadIndex(indexKey: key)
        }
    }

    /// The text to embed, or `nil` when the entry stays out of the index.
    /// Remote providers never receive secrets, financial data, file paths or
    /// Tailnet-received entries.
    static func documentText(for candidate: SemanticEmbeddingCandidate, configuration: SemanticSearchConfiguration) -> String? {
        if !configuration.isOnDevice {
            guard candidate.allowsCloudUpload else { return nil }
            let sensitive = JevEligibility.sensitiveCategories
            if sensitive.contains(candidate.contentType) { return nil }
            if sensitive.contains(where: { candidate.contentTypeMask.contains($0) }) { return nil }
        }
        return SemanticDocument.text(for: SemanticDocument.Input(
            content: candidate.content,
            contentType: candidate.contentType,
            sourceApp: candidate.sourceApp
        ))
    }

    private func pause(after error: Error, generation: Int) {
        guard !Task.isCancelled, generation == indexingGeneration else { return }
        PastaLogger.logError(error, logger: PastaLogger.search, context: "Semantic indexing paused")
        status.lastError = error.localizedDescription
        if (error as? SemanticSearchError)?.requiresConfigurationChange == true {
            isPausedForConfiguration = true
            return
        }
        let retryAt = Date().addingTimeInterval(Self.retryDelay)
        status.retryAt = retryAt
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.resumeAfterRetryDelay()
        }
    }

    private func resumeAfterRetryDelay() {
        retryTask = nil
        status.retryAt = nil
        scheduleIndexing()
    }

    private func loadIndex(indexKey: String) {
        index.removeAll()
        do {
            for (id, vector) in try database.fetchSemanticVectors(indexKey: indexKey) {
                index.upsert(id: id, vector: vector)
            }
            loadedIndexKey = indexKey
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.search, context: "Failed to load semantic index")
            loadedIndexKey = nil
        }
    }

    private func refreshCounts() {
        guard embedder != nil else { return }
        if let counts = try? database.semanticIndexCounts(indexKey: configuration.indexKey) {
            status.counts = counts
        }
    }

    private func cacheQuery(_ key: String, vector: [Float]) {
        queryCache[key] = vector
        queryCacheOrder.append(key)
        if queryCacheOrder.count > Self.queryCacheLimit {
            queryCache.removeValue(forKey: queryCacheOrder.removeFirst())
        }
    }

    private func cancelQueryOperations() {
        for operation in queryOperations.values { operation.cancel() }
        queryOperations.removeAll()
    }

    private func clearQueryCache() {
        queryCache.removeAll()
        queryCacheOrder.removeAll()
    }
}

/// Merges keyword (FTS5) and semantic results with reciprocal rank fusion.
public enum HybridSearchRanking {
    /// Standard RRF constant; dampens the advantage of the very top ranks.
    static let rankConstant = 60.0
    /// Slightly below 1 so keyword hits win ties against semantic-only hits.
    static let semanticWeight = 0.9

    /// Keyword results first where they tie, entries in both lists boosted,
    /// exact keyword matches kept on top.
    /// Shortest query worth sending to the embeddings provider.
    public static let minimumSemanticQueryLength = 3
    /// Time a query must stay unchanged before it is embedded, so typing
    /// does not send a request per keystroke.
    public static let semanticDebounceNanoseconds: UInt64 = 350_000_000

    public static func shouldRunSemantic(for query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumSemanticQueryLength && !trimmed.hasPrefix("!")
    }

    /// Fuses both lists, keeping entries that literally contain the query
    /// above meaning-only matches.
    public static func merge(keyword: [ClipboardEntry], semantic: [ClipboardEntry], query: String, limit: Int) -> [ClipboardEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = Set(keyword.lazy.filter { !needle.isEmpty && $0.content.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id))
        return fuse(keyword: keyword, semantic: semantic, exactMatchIDs: exact, limit: limit)
    }

    public static func fuse(keyword: [ClipboardEntry], semantic: [ClipboardEntry], exactMatchIDs: Set<UUID> = [], limit: Int) -> [ClipboardEntry] {
        guard !semantic.isEmpty else { return Array(keyword.prefix(limit)) }
        var scores: [UUID: Double] = [:]
        var entries: [UUID: ClipboardEntry] = [:]
        var firstSeen: [UUID: Int] = [:]
        for (rank, entry) in keyword.enumerated() {
            scores[entry.id, default: 0] += 1 / (rankConstant + Double(rank + 1))
            entries[entry.id] = entry
            firstSeen[entry.id] = firstSeen[entry.id] ?? rank
        }
        for (rank, entry) in semantic.enumerated() {
            scores[entry.id, default: 0] += semanticWeight / (rankConstant + Double(rank + 1))
            if entries[entry.id] == nil { entries[entry.id] = entry }
            firstSeen[entry.id] = firstSeen[entry.id] ?? (keyword.count + rank)
        }
        let ordered = scores.keys.sorted { lhs, rhs in
            let lhsExact = exactMatchIDs.contains(lhs), rhsExact = exactMatchIDs.contains(rhs)
            if lhsExact != rhsExact { return lhsExact }
            if scores[lhs]! != scores[rhs]! { return scores[lhs]! > scores[rhs]! }
            return firstSeen[lhs]! < firstSeen[rhs]!
        }
        return ordered.prefix(limit).compactMap { entries[$0] }
    }
}
