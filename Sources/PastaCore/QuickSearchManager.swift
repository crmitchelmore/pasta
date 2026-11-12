import Combine
import Foundation

/// Singleton manager that keeps quick search data pre-indexed and ready.
/// This ensures instant appearance when the hotkey is pressed.
/// Uses SQLite FTS5 for blazing fast search (sub-10ms for 10k+ entries).
@MainActor
public final class QuickSearchManager: ObservableObject {
    public static let shared = QuickSearchManager()
    
    // MARK: - Published State
    
    @Published public var query: String = ""
    @Published public var selectedFilter: ContentType? = nil
    @Published public var showPinnedOnly: Bool = false
    @Published public private(set) var results: [ClipboardEntry] = []
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var availableFilters: [FilterInfo] = []
    @Published public private(set) var pinnedCount: Int = 0
    @Published public private(set) var totalCount: Int? = nil
    @Published public private(set) var isUsingLoadedHistory: Bool = true
    @Published public private(set) var isReady: Bool = false
    /// Results found by meaning rather than by their text.
    @Published public private(set) var semanticMatchIDs: Set<UUID> = []
    
    // Command mode state
    @Published public private(set) var isCommandMode: Bool = false
    @Published public private(set) var commandResults: [Command] = []
    
    public struct FilterInfo: Equatable, Sendable {
        public let type: ContentType
        public let count: Int
    }
    
    // MARK: - Private State
    
    private var allEntries: [ClipboardEntry] = []
    private var entriesSubscription: AnyCancellable?
    private var searchDebounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var countsTask: Task<Void, Never>?
    
    // Database reference for FTS5 search
    private var database: DatabaseManager?
    private var semanticSearch: SemanticSearchService?
    
    init() {}

    public var resultSummary: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isUsingLoadedHistory
                ? "Up to 50 recent items · loaded history only"
                : "Up to 50 recent items · all history"
        }
        if !semanticMatchIDs.isEmpty {
            return "Up to 20 matches · including related by meaning"
        }
        return isUsingLoadedHistory
            ? "Up to 20 matches · loaded history only"
            : "Up to 20 matches · all history"
    }
    
    // MARK: - Public API
    
    /// Call once at app startup to begin indexing
    public func initialize(
        entriesPublisher: AnyPublisher<[ClipboardEntry], Never>,
        initialEntries: [ClipboardEntry] = [],
        database: DatabaseManager? = nil,
        semanticSearch: SemanticSearchService? = nil
    ) {
        PastaLogger.search.debug("QuickSearchManager.initialize called: initialEntries=\(initialEntries.count)")
        
        self.database = database
        self.semanticSearch = semanticSearch
        countsTask?.cancel()
        totalCount = nil
        pinnedCount = 0
        availableFilters = []
        isUsingLoadedHistory = database == nil
        
        // Load initial entries immediately (don't wait for publisher)
        updateEntries(initialEntries)
        
        entriesSubscription = entriesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                PastaLogger.search.debug("QuickSearchManager received from publisher: \(entries.count) entries")
                self?.updateEntries(entries)
            }
    }
    
    /// Reset state for fresh search (call when showing quick search)
    public func prepareForSearch() {
        searchDebounceTask?.cancel()
        searchTask?.cancel()
        query = ""
        selectedFilter = nil
        showPinnedOnly = false
        selectedIndex = 0
        isCommandMode = false
        commandResults = []
        computeAvailableFilters()
        updateResultsImmediate()
        PastaLogger.search.debug("prepareForSearch: allEntries=\(allEntries.count), results=\(results.count)")
    }
    
    /// Move selection up or down
    public func moveSelection(by delta: Int) {
        let maxIndex: Int
        if isCommandMode {
            maxIndex = min(commandResults.count, 9) - 1
        } else {
            maxIndex = results.count - 1
        }
        guard maxIndex >= 0 else { return }
        selectedIndex = max(0, min(maxIndex, selectedIndex + delta))
    }
    
    /// Get the currently selected entry (for clipboard mode)
    public var selectedEntry: ClipboardEntry? {
        guard !isCommandMode, selectedIndex >= 0 && selectedIndex < results.count else { return nil }
        return results[selectedIndex]
    }
    
    /// Get the currently selected command (for command mode)
    public var selectedCommand: Command? {
        guard isCommandMode, selectedIndex >= 0 && selectedIndex < commandResults.count else { return nil }
        return commandResults[selectedIndex]
    }
    
    // MARK: - Entry Updates
    
    private func updateEntries(_ entries: [ClipboardEntry]) {
        allEntries = entries
        isReady = true
        PastaLogger.search.debug("Entries updated: \(entries.count) entries (FTS5 search ready)")
        
        // Update filters
        computeAvailableFilters()
        
        // If showing results, refresh them
        if isCommandMode {
            return
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateResultsImmediate()
        } else {
            // Content changed, re-search
            performSearch()
        }
    }
    
    private func computeAvailableFilters() {
        countsTask?.cancel()
        let database = database
        let snapshot = allEntries
        countsTask = Task { [weak self] in
            let result = await withCancellableDetachedTask(priority: .utility) {
                Result {
                    try Task.checkCancellation()
                    if let database { return try database.quickSearchCounts() }
                    var counts = QuickSearchCounts()
                    for entry in snapshot {
                        counts.types[entry.contentType, default: 0] += 1
                        counts.total += 1
                        if entry.isPinned { counts.pinned += 1 }
                    }
                    return counts
                }
            }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let counts):
                applyCounts(counts)
            case .failure(let error):
                PastaLogger.logError(error, logger: PastaLogger.search, context: "Quick Search history counts failed")
                totalCount = nil
                pinnedCount = 0
                availableFilters = []
            }
        }
    }

    private func applyCounts(_ counts: QuickSearchCounts) {
        totalCount = counts.total
        pinnedCount = counts.pinned
        availableFilters = counts.types
            .filter { $0.value > 0 }
            .sorted {
                $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value
            }
            .map { FilterInfo(type: $0.key, count: $0.value) }
    }
    
    // MARK: - Search
    
    /// Called when query or filter changes - debounced search with immediate text display
    public func searchQueryChanged() {
        searchDebounceTask?.cancel()
        searchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for command mode (query starts with !)
        if trimmed.hasPrefix("!") {
            isCommandMode = true
            let commandQuery = String(trimmed.dropFirst())
            commandResults = CommandRegistry.shared.search(query: commandQuery)
            if let snippetQuery = SnippetCommands.searchQuery(commandQuery), let database {
                commandResults = []
                searchTask = Task { @MainActor in
                    do {
                        let snippets = try await Task.detached(priority: .userInitiated) {
                            try SnippetStore(database: database).find(matching: snippetQuery)
                        }.value
                        guard !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                        commandResults = SnippetCommands.commands(for: snippets)
                    } catch {
                        PastaLogger.logError(error, logger: PastaLogger.search, context: "Snippet search failed")
                    }
                }
            }
            selectedIndex = 0
            results = []
            return
        }
        
        // Exit command mode if no longer starting with !
        if isCommandMode {
            isCommandMode = false
            commandResults = []
        }
        
        // Empty query = immediate results
        if trimmed.isEmpty {
            updateResultsImmediate()
            return
        }
        
        // Short queries (1-2 chars) are the broadest prefix scans, so they get the
        // longest debounce — running them on every keystroke queues expensive work
        // that the next keystroke immediately invalidates.
        let debounceNanoseconds: UInt64 = trimmed.count <= 2 ? 50_000_000 : 25_000_000  // 50ms or 25ms

        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }
    
    private func updateResultsImmediate() {
        searchTask?.cancel()
        selectedIndex = 0
        semanticMatchIDs = []

        results = Array(allEntries.prefix(200).lazy
            .filter { !self.showPinnedOnly || $0.isPinned }
            .filter { self.selectedFilter == nil || $0.contentType == self.selectedFilter }
            .prefix(50))
        isUsingLoadedHistory = true

        let database = database
        let snapshot = allEntries
        let filter = selectedFilter
        let pinned = showPinnedOnly
        searchTask = Task { [weak self] in
            let recent = await withCancellableDetachedTask(priority: .userInitiated) {
                Result {
                    try Task.checkCancellation()
                    if let database {
                        return try database.fetchRecent(contentType: filter, limit: 50, pinnedOnly: pinned)
                    }
                    return Array(snapshot.lazy
                        .filter { !pinned || $0.isPinned }
                        .filter { filter == nil || $0.contentType == filter }
                        .prefix(50))
                }
            }
            guard !Task.isCancelled, let self,
                  query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selectedFilter == filter, showPinnedOnly == pinned else { return }
            switch recent {
            case .success(let entries):
                results = entries
                selectedIndex = min(selectedIndex, max(0, entries.count - 1))
                isUsingLoadedHistory = database == nil
            case .failure(let error):
                PastaLogger.logError(error, logger: PastaLogger.search, context: "Quick Search recent history failed")
            }
        }
    }
    
    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            updateResultsImmediate()
            return
        }
        
        selectedIndex = 0

        let querySnapshot = trimmed
        let filterSnapshot = selectedFilter
        let pinnedSnapshot = showPinnedOnly
        let dbSnapshot = database
        let entriesSnapshot = allEntries

        searchTask?.cancel()
        searchTask = Task {
            let searchResult = await withCancellableDetachedTask(priority: .userInitiated) { () -> (entries: [ClipboardEntry], loadedOnly: Bool)? in
                // A superseded query must not keep the DB queue busy.
                guard !Task.isCancelled else { return nil }

                if let dbSnapshot {
                    do {
                        let startTime = CFAbsoluteTimeGetCurrent()
                        let matches = try dbSnapshot.searchFTS(query: querySnapshot, contentType: filterSnapshot, limit: 20, pinnedOnly: pinnedSnapshot)
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        PastaLogger.search.debug("FTS5 search: \(matches.count) results in \(String(format: "%.1f", elapsed))ms")
                        return (matches, false)
                    } catch {
                        PastaLogger.search.error("FTS5 search failed: \(PastaLogger.diagnosticDescription(error))")
                    }
                }

                guard !Task.isCancelled else { return nil }
                return (Self.fallbackMatches(query: querySnapshot, entries: entriesSnapshot, filter: filterSnapshot, pinnedOnly: pinnedSnapshot), true)
            }

            guard !Task.isCancelled, let searchResult else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == querySnapshot else { return }
            guard selectedFilter == filterSnapshot else { return }
            guard showPinnedOnly == pinnedSnapshot else { return }
            results = searchResult.entries
            isUsingLoadedHistory = searchResult.loadedOnly
            semanticMatchIDs = []

            await mergeSemanticMatches(query: querySnapshot, keyword: searchResult.entries,
                                       filter: filterSnapshot, pinnedOnly: pinnedSnapshot)
        }
    }

    /// Second phase: once typing settles, blend in entries related by meaning.
    private func mergeSemanticMatches(query: String, keyword: [ClipboardEntry], filter: ContentType?, pinnedOnly: Bool) async {
        guard let semanticSearch, HybridSearchRanking.shouldRunSemantic(for: query) else { return }
        try? await Task.sleep(nanoseconds: HybridSearchRanking.semanticDebounceNanoseconds)
        guard !Task.isCancelled else { return }

        let semantic = await semanticSearch.searchEntries(query: query, limit: 20) { entry in
            (filter == nil || entry.contentType == filter) && (!pinnedOnly || entry.isPinned)
        }
        guard !Task.isCancelled, !semantic.isEmpty,
              self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query,
              selectedFilter == filter, showPinnedOnly == pinnedOnly else { return }

        let keywordIDs = Set(keyword.map(\.id))
        let merged = HybridSearchRanking.merge(keyword: keyword, semantic: semantic, query: query, limit: 20)
        let selectedID = selectedEntry?.id
        results = merged
        semanticMatchIDs = Set(merged.lazy.map(\.id).filter { !keywordIDs.contains($0) })
        selectedIndex = selectedID.flatMap { id in merged.firstIndex { $0.id == id } } ?? 0
    }

    private nonisolated static func fallbackMatches(query: String, entries: [ClipboardEntry], filter: ContentType?, pinnedOnly: Bool) -> [ClipboardEntry] {
        let lower = query.lowercased()
        let filtered = entries.lazy.filter {
            $0.content.lowercased().contains(lower)
                && (filter == nil || $0.contentType == filter)
                && (!pinnedOnly || $0.isPinned)
        }
        return Array(filtered.prefix(20))
    }
}
