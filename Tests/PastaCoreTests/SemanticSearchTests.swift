import Foundation
import XCTest
@testable import PastaCore

final class SemanticSearchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SemanticSearchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        SemanticMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Documents

    func testOpaqueSerialFromContinuityIsDescribedAsSerialFromAnAppleDevice() throws {
        let text = try XCTUnwrap(SemanticDocument.text(
            for: .init(content: "F4GXK2J1HG7Q", contentType: .text, sourceApp: "Continuity"),
            appName: { _ in nil }
        ))
        XCTAssertTrue(text.contains("serial number"), text)
        XCTAssertTrue(text.contains("another Apple device"), text)
        XCTAssertTrue(text.hasSuffix("\nF4GXK2J1HG7Q"), text)
    }

    func testShapeHintsCoverCodesNumbersAndIgnoreWords() {
        XCTAssertTrue(SemanticDocument.shapeHint(for: "482913")?.contains("one-time passcode") == true)
        XCTAssertTrue(SemanticDocument.shapeHint(for: "1Z999AA10123456784")?.contains("serial number") == true)
        XCTAssertTrue(SemanticDocument.shapeHint(for: "ABCD-1234-EFGH-5678")?.contains("licence or product key") == true)
        XCTAssertTrue(SemanticDocument.shapeHint(for: "aB3dE5fG")?.contains("password") == true)
        XCTAssertNil(SemanticDocument.shapeHint(for: "hello"))
        XCTAssertNil(SemanticDocument.shapeHint(for: "two words 123"))
        XCTAssertNil(SemanticDocument.text(for: .init(content: "x", contentType: .image, sourceApp: nil)))
        XCTAssertNil(SemanticDocument.text(for: .init(content: "  \n", contentType: .text, sourceApp: nil)))
    }

    func testRemoteProvidersNeverReceivePrivateEntries() {
        let remote = SemanticSearchConfiguration(isEnabled: true, provider: .openAI)
        let local = SemanticSearchConfiguration(isEnabled: true, provider: .openAICompatible)
        XCTAssertFalse(remote.isOnDevice)
        XCTAssertTrue(local.isOnDevice)

        let plain = candidate("meeting notes", type: .text)
        let apiKey = candidate("sk-live-123", type: .apiKey)
        let maskedSecret = candidate("token here", type: .text, mask: .jwt)
        let tailnet = candidate("from my other mac", type: .text, allowsCloudUpload: false)
        let path = candidate("/Users/me/secret.txt", type: .filePath, allowsCloudUpload: false)

        XCTAssertNotNil(SemanticSearchService.documentText(for: plain, configuration: remote))
        for privateCandidate in [apiKey, maskedSecret, tailnet, path] {
            XCTAssertNil(SemanticSearchService.documentText(for: privateCandidate, configuration: remote), privateCandidate.content)
            XCTAssertNotNil(SemanticSearchService.documentText(for: privateCandidate, configuration: local), privateCandidate.content)
        }
    }

    func testTailnetAndICloudExcludedEntriesAreNotUploadable() throws {
        let database = try DatabaseManager.inMemory()
        var tailnet = ClipboardEntry(content: "tailnet text", contentType: .text)
        tailnet.receivedViaTailnet = true
        let localOnly = ClipboardEntry(content: "local only", contentType: .text, cloudSyncAllowed: false)
        let normal = ClipboardEntry(content: "normal", contentType: .text)
        try database.insertBatch([tailnet, localOnly, normal])

        let candidates = try database.pendingSemanticCandidates(indexKey: "k", limit: 10)
        let uploadable = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.allowsCloudUpload) })
        XCTAssertEqual(uploadable[tailnet.id], false)
        XCTAssertEqual(uploadable[localOnly.id], false)
        XCTAssertEqual(uploadable[normal.id], true)
    }

    // MARK: - Storage

    func testEmbeddingsTrackContentChangesIndexKeysAndDeletion() throws {
        let database = try DatabaseManager.inMemory()
        let first = ClipboardEntry(content: "alpha", contentType: .text, timestamp: Date(timeIntervalSince1970: 1))
        let second = ClipboardEntry(content: "beta", contentType: .text, timestamp: Date(timeIntervalSince1970: 2))
        try database.insertBatch([first, second])

        var pending = try database.pendingSemanticCandidates(indexKey: "k1", limit: 10)
        XCTAssertEqual(pending.map(\.id), [second.id, first.id])

        let written = try database.saveSemanticEmbeddings([
            SemanticEmbeddingRecord(candidate: pending[0], vector: [1, 0]),
            SemanticEmbeddingRecord(candidate: pending[1], vector: nil)
        ], indexKey: "k1")
        XCTAssertEqual(written, 2)
        XCTAssertEqual(try database.pendingSemanticCandidates(indexKey: "k1", limit: 10), [])
        XCTAssertEqual(try database.semanticIndexCounts(indexKey: "k1"), SemanticIndexCounts(indexed: 1, skipped: 1, total: 2))
        let vectors = try database.fetchSemanticVectors(indexKey: "k1")
        XCTAssertEqual(vectors.map(\.id), [second.id])
        XCTAssertEqual(vectors.first?.vector, [1, 0])

        // Another model's vectors are not current.
        XCTAssertEqual(try database.pendingSemanticCandidates(indexKey: "k2", limit: 10).count, 2)
        XCTAssertEqual(try database.deleteSemanticEmbeddings(notMatching: "k2"), 2)

        try database.saveSemanticEmbeddings(pending.map { SemanticEmbeddingRecord(candidate: $0, vector: [0, 1]) }, indexKey: "k2")
        try database.delete(id: second.id)
        XCTAssertEqual(try database.semanticIndexCounts(indexKey: "k2"), SemanticIndexCounts(indexed: 1, skipped: 0, total: 1))

        // Rows deleted before their vector arrives are not stored.
        pending = [pending[0]]
        XCTAssertEqual(try database.saveSemanticEmbeddings([SemanticEmbeddingRecord(candidate: pending[0], vector: [1, 1])], indexKey: "k2"), 0)
    }

    func testFetchEntriesKeepsRequestedOrderAndDropsMissingIDs() throws {
        let database = try DatabaseManager.inMemory()
        let a = ClipboardEntry(content: "a", contentType: .text)
        let b = ClipboardEntry(content: "b", contentType: .text)
        try database.insertBatch([a, b])
        XCTAssertEqual(try database.fetchEntries(ids: [b.id, UUID(), a.id]).map(\.id), [b.id, a.id])
    }

    // MARK: - Vector index and relevance

    func testVectorIndexRanksByCosineAndSupportsUpdatesAndRemoval() {
        var index = SemanticVectorIndex()
        let a = UUID(), b = UUID(), c = UUID()
        index.upsert(id: a, vector: unit([1, 0, 0]))
        index.upsert(id: b, vector: unit([1, 1, 0]))
        index.upsert(id: c, vector: unit([0, 0, 1]))

        XCTAssertEqual(index.search(unit([1, 0.1, 0]), limit: 3).map(\.id), [a, b, c])
        XCTAssertEqual(index.search(unit([1, 0, 0]), limit: 1).first?.score ?? 0, 1, accuracy: 1e-5)

        index.upsert(id: a, vector: unit([0, 0, 1]))
        XCTAssertEqual(index.search(unit([0, 0, 1]), limit: 2).map(\.id).sorted(by: { $0.uuidString < $1.uuidString }),
                       [a, c].sorted(by: { $0.uuidString < $1.uuidString }))

        index.remove(id: a)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.search(unit([1, 1, 0]), limit: 1).map(\.id), [b])
        XCTAssertEqual(index.search(unit([1, 1]), limit: 3), [], "Mismatched dimensions return nothing")

        index.upsert(id: a, vector: unit([1, 0]))
        XCTAssertEqual(index.count, 1, "A new vector size resets the index")
    }

    func testRelevantHitsKeepOnlyResultsThatStandOut() {
        let ids = (0..<20).map { _ in UUID() }
        let hits = [SemanticVectorIndex.Hit(id: ids[0], score: 0.62)]
            + ids.dropFirst().map { SemanticVectorIndex.Hit(id: $0, score: 0.2) }
        XCTAssertEqual(SemanticSearchService.relevantHits(hits, limit: 10).map(\.id), [ids[0]])

        let flat = ids.map { SemanticVectorIndex.Hit(id: $0, score: 0.3) }
        XCTAssertEqual(SemanticSearchService.relevantHits(flat, limit: 5).count, 5)
        XCTAssertEqual(SemanticSearchService.relevantHits([.init(id: ids[0], score: -0.1)], limit: 5), [])
    }

    // MARK: - Hybrid ranking

    func testMergeKeepsLiteralMatchesFirstThenFusesBothLists() {
        let literal = ClipboardEntry(content: "my apple watch", contentType: .text)
        let both = ClipboardEntry(content: "watch strap order", contentType: .text)
        let semanticOnly = ClipboardEntry(content: "F4GXK2J1HG7Q", contentType: .text)
        let keywordOnly = ClipboardEntry(content: "watchtower", contentType: .text)

        let merged = HybridSearchRanking.merge(
            keyword: [keywordOnly, both, literal],
            semantic: [semanticOnly, both],
            query: "Apple Watch",
            limit: 10
        )
        XCTAssertEqual(merged.map(\.id), [literal.id, both.id, keywordOnly.id, semanticOnly.id])
        XCTAssertEqual(HybridSearchRanking.merge(keyword: [keywordOnly], semantic: [], query: "x", limit: 10).map(\.id), [keywordOnly.id])
        XCTAssertEqual(HybridSearchRanking.fuse(keyword: [], semantic: [semanticOnly, both], limit: 1).map(\.id), [semanticOnly.id])
    }

    func testSemanticQueriesNeedThreeCharactersAndSkipNegation() {
        XCTAssertFalse(HybridSearchRanking.shouldRunSemantic(for: " ab "))
        XCTAssertFalse(HybridSearchRanking.shouldRunSemantic(for: "!secret"))
        XCTAssertTrue(HybridSearchRanking.shouldRunSemantic(for: "serial"))
    }

    // MARK: - Configuration

    func testValidationIsTiedToProviderEndpointModelAndKey() {
        var configuration = SemanticSearchConfiguration(isEnabled: true, provider: .openAI)
        configuration.save(defaults: defaults)
        XCTAssertFalse(configuration.isActive(apiKey: "sk-1", defaults: defaults))
        configuration.recordSuccessfulValidation(apiKey: "sk-1", defaults: defaults)
        XCTAssertTrue(configuration.isActive(apiKey: " sk-1 ", defaults: defaults))
        XCTAssertFalse(configuration.isActive(apiKey: "sk-2", defaults: defaults))
        XCTAssertFalse(configuration.isActive(apiKey: nil, defaults: defaults))

        configuration.model = "text-embedding-3-large"
        XCTAssertFalse(configuration.isActive(apiKey: "sk-1", defaults: defaults))

        configuration.endpoint = "http://example.com/v1/embeddings"
        XCTAssertNil(configuration.endpointURL, "Plain HTTP is only allowed to loopback hosts")
        configuration.endpoint = "http://127.0.0.1:1234/v1/embeddings"
        XCTAssertNotNil(configuration.endpointURL)

        SemanticSearchConfiguration.invalidateValidation(defaults: defaults)
        XCTAssertFalse(SemanticSearchConfiguration.load(defaults: defaults).isEnabled)
    }

    func testIndexKeyChangesWithTheVectorSpace() {
        let small = SemanticSearchConfiguration(provider: .openAI)
        let large = SemanticSearchConfiguration(provider: .openAI, model: "text-embedding-3-large")
        let azure = SemanticSearchConfiguration(provider: .azureOpenAI, endpoint: "https://contoso.openai.azure.com/openai/v1/embeddings")
        XCTAssertEqual(small.requestedDimensions, 512)
        XCTAssertNil(SemanticSearchConfiguration(provider: .openAICompatible).requestedDimensions)
        XCTAssertEqual(Set([small.indexKey, large.indexKey, azure.indexKey]).count, 3)
    }

    // MARK: - Client

    func testClientSendsProviderSpecificAuthAndDecodesOutOfOrderVectors() async throws {
        let session = SemanticMockURLProtocol.session()
        SemanticMockURLProtocol.respond { _ in
            (200, #"{"data":[{"index":1,"embedding":[0,2]},{"index":0,"embedding":[3,4]}]}"#)
        }

        let azure = SemanticSearchConfiguration(provider: .azureOpenAI, endpoint: "https://contoso.openai.azure.com/openai/v1/embeddings", model: "my-deployment")
        let vectors = try await RemoteEmbeddingClient(configuration: azure, apiKey: "az-key", session: session, retryPolicy: .none)
            .embed(["first", "second"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0][0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(vectors[0][1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(vectors[1], [0, 1])

        let request = try XCTUnwrap(SemanticMockURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "az-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SemanticMockURLProtocol.bodies.first ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "my-deployment")
        XCTAssertEqual(body["input"] as? [String], ["first", "second"])
        XCTAssertNil(body["dimensions"], "Custom deployment names keep the model's native size")

        let openAI = try RemoteEmbeddingClient(configuration: .init(provider: .openAI), apiKey: "sk-1").makeRequest(["x"])
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
        let openAIBody = try XCTUnwrap(JSONSerialization.jsonObject(with: openAI.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(openAIBody["dimensions"] as? Int, 512)
        XCTAssertThrowsError(try RemoteEmbeddingClient(configuration: .init(provider: .openAI), apiKey: " ").makeRequest(["x"]))
        XCTAssertNoThrow(try RemoteEmbeddingClient(configuration: .init(provider: .openAICompatible), apiKey: nil).makeRequest(["x"]))
    }

    func testClientMapsAuthFailuresAndRejectsMalformedResponses() async throws {
        let session = SemanticMockURLProtocol.session()
        let client = RemoteEmbeddingClient(configuration: .init(provider: .openAI), apiKey: "sk-1", session: session, retryPolicy: .none)

        SemanticMockURLProtocol.respond { _ in (401, #"{"error":{"message":"Incorrect API key"}}"#) }
        do {
            _ = try await client.embed(["x"])
            XCTFail("Expected unauthorized")
        } catch let error as SemanticSearchError {
            guard case .unauthorized = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(error.requiresConfigurationChange)
        }

        SemanticMockURLProtocol.respond { _ in (200, #"{"data":[{"index":0,"embedding":[0,0]}]}"#) }
        do {
            _ = try await client.embed(["x"])
            XCTFail("Expected invalid response")
        } catch let error as SemanticSearchError {
            guard case .invalidResponse = error else { return XCTFail("Got \(error)") }
        }
    }

    // MARK: - Service

    func testServiceIndexesHistoryAndFindsOpaqueSerialByMeaning() async throws {
        let database = try DatabaseManager.inMemory()
        let serial = ClipboardEntry(content: "F4GXK2J1HG7Q", contentType: .text, timestamp: Date(timeIntervalSince1970: 1), sourceApp: "Continuity")
        let others = [
            ClipboardEntry(content: "Let's grab lunch on Friday", contentType: .prose, timestamp: Date(timeIntervalSince1970: 2)),
            ClipboardEntry(content: "https://github.com/crmitchelmore/pasta", contentType: .url, timestamp: Date(timeIntervalSince1970: 3)),
            ClipboardEntry(content: "let total = items.reduce(0, +)", contentType: .code, timestamp: Date(timeIntervalSince1970: 4)),
            ClipboardEntry(content: "Remember to water the plants", contentType: .prose, timestamp: Date(timeIntervalSince1970: 5)),
            ClipboardEntry(content: "sk-should-never-leave", contentType: .apiKey, timestamp: Date(timeIntervalSince1970: 6))
        ]
        try database.insertBatch([serial] + others)

        let embedder = BagOfWordsEmbedder()
        let service = try makeActiveService(database: database, embedder: embedder)
        await service.reloadConfiguration()
        try await waitForIndexing(service, indexed: 5, skipped: 1)

        XCTAssertFalse(embedder.allInputs.contains { $0.contains("sk-should-never-leave") }, "Secrets must not be sent to a remote provider")

        let results = await service.searchEntries(query: "apple watch serial number", limit: 5)
        XCTAssertEqual(results.first?.id, serial.id)

        let filtered = await service.searchEntries(query: "apple watch serial number", limit: 5, where: { $0.contentType != .text })
        XCTAssertFalse(filtered.contains { $0.id == serial.id })

        // New entries are picked up incrementally.
        let added = ClipboardEntry(content: "Order 1Z999AA10123456784 shipped", contentType: .text, timestamp: Date(timeIntervalSince1970: 7))
        try database.insert(added)
        await service.scheduleIndexing()
        try await waitForIndexing(service, indexed: 6, skipped: 1)
    }

    func testServiceStaysOffUntilValidatedAndClearsMemoryWhenDisabled() async throws {
        let database = try DatabaseManager.inMemory()
        try database.insert(ClipboardEntry(content: "hello", contentType: .text))
        let embedder = BagOfWordsEmbedder()
        let configuration = SemanticSearchConfiguration(isEnabled: true, provider: .openAI)
        configuration.save(defaults: defaults)
        let service = SemanticSearchService(database: database, defaults: defaults, keyProvider: { _ in "sk-test" }, embedderFactory: { _, _ in embedder })

        await service.reloadConfiguration()
        let inactiveStatus = await service.currentStatus()
        XCTAssertFalse(inactiveStatus.isActive)
        XCTAssertTrue(embedder.allInputs.isEmpty)

        configuration.recordSuccessfulValidation(apiKey: "sk-test", defaults: defaults)
        await service.reloadConfiguration()
        try await waitForIndexing(service, indexed: 1, skipped: 0)

        var disabled = configuration
        disabled.isEnabled = false
        disabled.save(defaults: defaults)
        await service.reloadConfiguration()
        let results = await service.search(query: "hello", limit: 5)
        XCTAssertEqual(results, [])
        XCTAssertEqual(try database.semanticIndexCounts(indexKey: configuration.indexKey).indexed, 1, "Disabling keeps stored vectors")
    }

    func testServicePausesOnProviderErrorsWithoutLooping() async throws {
        let database = try DatabaseManager.inMemory()
        try database.insert(ClipboardEntry(content: "hello", contentType: .text))
        let embedder = BagOfWordsEmbedder(error: SemanticSearchError.unauthorized("bad key"))
        let service = try makeActiveService(database: database, embedder: embedder)
        await service.reloadConfiguration()

        for _ in 0..<300 {
            let status = await service.currentStatus()
            if !status.isIndexing, status.lastError != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = await service.currentStatus()
        XCTAssertNotNil(status.lastError)
        XCTAssertNil(status.retryAt, "Configuration errors wait for a settings change")
        XCTAssertEqual(embedder.callCount, 1)
    }

    // MARK: - Helpers

    private func makeActiveService(database: DatabaseManager, embedder: BagOfWordsEmbedder) throws -> SemanticSearchService {
        let configuration = SemanticSearchConfiguration(isEnabled: true, provider: .openAI)
        configuration.save(defaults: defaults)
        configuration.recordSuccessfulValidation(apiKey: "sk-test", defaults: defaults)
        return SemanticSearchService(
            database: database,
            defaults: defaults,
            keyProvider: { _ in "sk-test" },
            embedderFactory: { _, _ in embedder }
        )
    }

    private func waitForIndexing(_ service: SemanticSearchService, indexed: Int, skipped: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            let status = await service.currentStatus()
            if !status.isIndexing, status.counts.indexed == indexed, status.counts.skipped == skipped { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = await service.currentStatus()
        XCTFail("Indexing did not finish: \(status)", file: file, line: line)
    }

    private func candidate(
        _ content: String,
        type: ContentType,
        mask: ContentTypeMask? = nil,
        allowsCloudUpload: Bool = true
    ) -> SemanticEmbeddingCandidate {
        SemanticEmbeddingCandidate(
            id: UUID(),
            storageID: UUID().uuidString,
            content: content,
            contentType: type,
            sourceApp: nil,
            contentHash: content,
            contentTypeMask: mask ?? ContentTypeMask(type) ?? [],
            allowsCloudUpload: allowsCloudUpload
        )
    }

    private func unit(_ vector: [Float]) -> [Float] {
        VectorMath.normalized(vector)!
    }
}

/// Deterministic stand-in for an embeddings model: hashed bag of lower-cased
/// words, so texts sharing words land close together.
final class BagOfWordsEmbedder: TextEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String] = []
    private var calls = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    var allInputs: [String] { lock.withLock { inputs } }
    var callCount: Int { lock.withLock { calls } }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock {
            calls += 1
            inputs += texts
        }
        if let error { throw error }
        return texts.map(Self.vector(for:))
    }

    static func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 256)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for word in words {
            let hash = word.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
            vector[Int(hash % 256)] += 1
        }
        vector[255] += 0.01
        return VectorMath.normalized(vector)!
    }
}

private final class SemanticMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, String)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recordedRequests: [URLRequest] = []
    private static var recordedBodies: [Data] = []

    static var requests: [URLRequest] { lock.withLock { recordedRequests } }
    static var bodies: [Data] { lock.withLock { recordedBodies } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SemanticMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func respond(_ newHandler: @escaping Handler) {
        lock.withLock { handler = newHandler }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recordedRequests = []
            recordedBodies = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recordedRequests.append(request)
            Self.recordedBodies.append(body)
            return Self.handler
        }
        let (status, text) = handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
