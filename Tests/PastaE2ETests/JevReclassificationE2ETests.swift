import Foundation
import XCTest
import PastaCore
import PastaDetectors

final class JevReclassificationE2ETests: XCTestCase {
    private var environment: E2ETempEnvironment!
    private var database: DatabaseManager!
    private var pipeline: E2ECapturePipeline!
    private let configuration = JevConfiguration(isEnabled: true, mode: .primary)

    override func setUpWithError() throws {
        environment = try E2ETempEnvironment(name: "jev-reclassification")
        database = try environment.openDatabase()
        pipeline = E2ECapturePipeline(database: database, imageStorage: try environment.openImageStorage(), detector: ContentTypeDetector())
    }

    override func tearDownWithError() throws {
        pipeline = nil
        database = nil
        environment.destroy()
        environment = nil
    }

    func testPersistedDedupIdentityIsReclassifiedWithoutLosingContentPinsOrCounts() throws {
        let capture = ClipboardEntry(content: "A short title", contentType: .text, isPinned: true)
        let first = try pipeline.ingest(capture)
        let recopy = ClipboardEntry(content: capture.content, contentType: .text)
        let second = try pipeline.ingest(recopy)
        let snapshot = try primarySnapshot(second)
        XCTAssertEqual(snapshot.id, first.persisted.first?.id)
        XCTAssertNotEqual(snapshot.id, recopy.id)
        XCTAssertEqual(snapshot.copyCount, 2)

        let result = try apply(.prose, to: snapshot)
        XCTAssertEqual(result, .applied)
        let updated = try XCTUnwrap(database.fetch(id: snapshot.id))
        XCTAssertEqual(updated.contentType, .prose)
        XCTAssertEqual(updated.content, capture.content)
        XCTAssertEqual(updated.copyCount, snapshot.copyCount)
        XCTAssertEqual(updated.timestamp, snapshot.timestamp)
        XCTAssertEqual(updated.isPinned, snapshot.isPinned)
        XCTAssertFalse(updated.isSynced)
        XCTAssertEqual(updated.contentTypeMask, MetadataParser.typeMask(for: updated.metadata))
        XCTAssertNil(try database.fetch(id: recopy.id))
        XCTAssertTrue(try database.searchFTS(query: "short", contentType: .prose, limit: 10).contains { $0.id == snapshot.id })
    }

    func testCategoryChangeRebuildsChildrenAndPreservesSharingConsent() throws {
        let text = "Read https://example.com and ask team@example.com for the launch notes."
        let captured = ClipboardEntry(content: text, contentType: .text, cloudSyncAllowed: false, receivedViaTailnet: true)
        let result = try pipeline.ingest(captured)
        let snapshot = try primarySnapshot(result)
        let oldIDs = Set(try database.fetchExtractedEntries(parentId: snapshot.id).map(\.id))
        XCTAssertFalse(oldIDs.isEmpty)
        XCTAssertEqual(try apply(.prose, to: snapshot), .applied)
        let children = try database.fetchExtractedEntries(parentId: snapshot.id)
        XCTAssertFalse(children.isEmpty)
        XCTAssertTrue(Set(children.map(\.id)).isDisjoint(with: oldIDs))
        XCTAssertTrue(children.allSatisfy { !$0.cloudSyncAllowed && $0.receivedViaTailnet && !$0.isSynced })
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.cloudSyncAllowed, false)
        let changed = try XCTUnwrap(database.fetch(id: snapshot.id))
        XCTAssertEqual(try apply(.url, to: changed), .applied)
        XCTAssertTrue(try database.fetchExtractedEntries(parentId: snapshot.id).isEmpty)
    }

    func testUnknownRetainsOriginalCategoryAndChildren() throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Read https://example.com before the launch.", contentType: .text))
        let snapshot = try primarySnapshot(result)
        let children = try database.fetchExtractedEntries(parentId: snapshot.id)
        XCTAssertEqual(try apply(.unknown, to: snapshot), .retained)
        XCTAssertEqual(try database.fetch(id: snapshot.id), snapshot)
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: snapshot.id), children)
    }

    func testInvalidExtractedParentRollsBackClassificationAndChildRetirement() throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Read https://example.com before the launch.", contentType: .text))
        let snapshot = try primarySnapshot(result)
        let children = try database.fetchExtractedEntries(parentId: snapshot.id)
        let invalidChild = ClipboardEntry(content: "https://example.com", contentType: .url, parentEntryId: UUID())
        XCTAssertThrowsError(try database.applyClassification(matching: snapshot, contentType: .prose,
                                                              metadata: nil, extractedEntries: [invalidChild]))
        XCTAssertEqual(try database.fetch(id: snapshot.id), snapshot)
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: snapshot.id), children)
        XCTAssertTrue(try database.pendingClassificationDeletions().isEmpty)
    }

    func testChangedOrDeletedSnapshotCannotBeOverwrittenOrResurrected() throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Original title", contentType: .text))
        let snapshot = try primarySnapshot(result)
        XCTAssertTrue(try database.applyClassification(matching: snapshot, contentType: .code, metadata: nil, extractedEntries: []))
        XCTAssertEqual(try apply(.prose, to: snapshot), .changedSinceRequest)
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.contentType, .code)
        try database.delete(id: snapshot.id)
        XCTAssertEqual(try apply(.prose, to: snapshot), .changedSinceRequest)
        XCTAssertNil(try database.fetch(id: snapshot.id))
    }

    func testStaleUploadCannotMarkNewClassificationSynced() throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "A title", contentType: .text))
        let snapshot = try primarySnapshot(result)
        XCTAssertEqual(try apply(.prose, to: snapshot), .applied)
        let updated = try XCTUnwrap(database.fetch(id: snapshot.id))
        try database.markSynced(matching: [updated])
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.isSynced, true)
        try database.markSynced(matching: [snapshot])
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.isSynced, false)
    }

    func testBackfillDetectsClassificationChangedWhileUploading() async throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Pending title", contentType: .text))
        let snapshot = try primarySnapshot(result)
        let db = try XCTUnwrap(database)
        do {
            _ = try await db.backfillUnsynced { entries, confirm in
                _ = try db.applyClassification(matching: snapshot, contentType: .prose, metadata: nil, extractedEntries: [])
                confirm(entries.map(\.id))
                return entries.count
            }
            XCTFail("Stale upload must leave newer classification pending")
        } catch let error as PendingSyncUploadsError {
            XCTAssertEqual(error.count, 1)
        }
        XCTAssertEqual(try db.fetch(id: snapshot.id)?.contentType, .prose)
        XCTAssertEqual(try db.fetch(id: snapshot.id)?.isSynced, false)
    }

    func testFilePasteAndSensitiveContentCannotBeRetypedWithoutConsent() throws {
        let file = ClipboardEntry(content: "/tmp/report.txt", contentType: .filePath, rawData: Data("file".utf8))
        _ = try database.insert(file, deduplicate: false)
        let storedFile = try XCTUnwrap(database.fetch(id: file.id))
        XCTAssertEqual(try apply(.prose, to: storedFile), .retained)
        XCTAssertEqual(try database.fetch(id: file.id), storedFile)
        let secret = ClipboardEntry(content: "mock-key", contentType: .apiKey)
        let storedSecret = try database.insert(secret, deduplicate: false).entry
        XCTAssertEqual(try apply(.text, to: storedSecret), .retained)
        XCTAssertEqual(try database.fetch(id: secret.id)?.contentType, .apiKey)
    }

    func testOptedInAuthoritativeCapturePreservesOriginalEnvBlockAndLegacyModeStillSplits() throws {
        let capture = ClipboardEntry(content: "FOO=one\nBAR=two", contentType: .text)
        XCTAssertGreaterThan(try pipeline.enrich(capture).envVarSplit.count, 0)
        pipeline.preserveEnvVarBlock = true
        let result = try pipeline.ingest(capture)
        XCTAssertTrue(result.envVarSplit.isEmpty)
        XCTAssertEqual(result.primary.contentType, .envVarBlock)
        XCTAssertEqual(result.persisted.first?.content, capture.content)
    }

    func testNetworkFailureKeepsDurableCaptureAndSuccessAppliesAfterProviderReturns() async throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Network-independent title", contentType: .text))
        let snapshot = try primarySnapshot(result)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ReclassificationURLProtocol.self]
        let classifier = JevClassifier(session: URLSession(configuration: sessionConfiguration), retryPolicy: .none)
        var remoteConfiguration = configuration
        remoteConfiguration.endpoint = "https://offline.example/v1/systemone"
        do {
            _ = try await classifier.classify(content: snapshot.content, configuration: remoteConfiguration, apiKey: "mock-key")
            XCTFail("Expected the offline provider to fail")
        } catch {
            XCTAssertEqual(try database.fetch(id: snapshot.id), snapshot)
        }
        remoteConfiguration.endpoint = "https://classification.example/v1/systemone"
        let decision = try await classifier.classify(content: snapshot.content, configuration: remoteConfiguration, apiKey: "mock-key")
        XCTAssertEqual(decision.category, .prose)
        XCTAssertEqual(try JevReclassificationService().apply(decision, to: snapshot, database: database,
                                                             configuration: remoteConfiguration, detectorConfiguration: .default,
                                                             extractContent: true), .applied)
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.content, snapshot.content)
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.contentType, .prose)
    }

    func testRetiredChildrenStayDeletedThroughCloudReplayAndDeletionUpload() async throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Read https://example.com and ask team@example.com for the launch notes.", contentType: .text))
        let snapshot = try primarySnapshot(result)
        let oldChildren = try database.fetchExtractedEntries(parentId: snapshot.id)
        XCTAssertFalse(oldChildren.isEmpty)
        XCTAssertEqual(try apply(.url, to: snapshot), .applied)
        XCTAssertEqual(Set(try database.pendingClassificationDeletions()), Set(oldChildren.map(\.id)))
        try database.applySyncChanges(modified: oldChildren, deleted: [])
        XCTAssertTrue(try database.fetchExtractedEntries(parentId: snapshot.id).isEmpty)

        let recorder = DeletionRecorder()
        _ = try await database.backfillUnsynced(deleting: { id in await recorder.record(id) }) { entries, confirm in
            confirm(entries.map(\.id))
            return entries.count
        }
        let uploadedDeletions = await recorder.ids
        XCTAssertEqual(Set(uploadedDeletions), Set(oldChildren.map(\.id)))
        XCTAssertTrue(try database.pendingClassificationDeletions().isEmpty)
        // Even a delayed pull fetched before the deletion cannot resurrect a child.
        try database.applySyncChanges(modified: oldChildren, deleted: [])
        XCTAssertTrue(try database.fetchExtractedEntries(parentId: snapshot.id).isEmpty)
        try database.applySyncChanges(modified: [], deleted: oldChildren.map(\.id))
    }

    func testFailedChildDeletionRemainsDurableAndBlocksPullBackfill() async throws {
        let result = try pipeline.ingest(ClipboardEntry(content: "Read https://example.com and ask team@example.com for the launch notes.", contentType: .text))
        let snapshot = try primarySnapshot(result)
        let oldChildren = try database.fetchExtractedEntries(parentId: snapshot.id)
        XCTAssertFalse(oldChildren.isEmpty)
        XCTAssertEqual(try apply(.url, to: snapshot), .applied)
        let db = try XCTUnwrap(database)
        do {
            _ = try await db.backfillUnsynced(deleting: { _ in throw URLError(.notConnectedToInternet) }) { _, _ in
                XCTFail("Uploads cannot run while deletions are unconfirmed")
                return 0
            }
            XCTFail("Offline deletion must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let reopened = try environment.openDatabase()
        XCTAssertEqual(Set(try reopened.pendingClassificationDeletions()), Set(oldChildren.map(\.id)))
        try reopened.applySyncChanges(modified: oldChildren, deleted: [])
        XCTAssertTrue(try reopened.fetchExtractedEntries(parentId: snapshot.id).isEmpty)
    }

    func testUploadAcknowledgementHandlesDatabaseTimestampPrecision() throws {
        let entry = ClipboardEntry(content: "Timestamp precision", contentType: .text,
                                   timestamp: Date(timeIntervalSince1970: 1_700_000_000.123456))
        let outcome = try database.insert(entry, deduplicate: false)
        try database.markSynced(matching: [outcome.entry])
        XCTAssertEqual(try database.fetch(id: entry.id)?.isSynced, true)
    }

    func testLiveQueueIsBoundedWithoutBlockingDurableCapture() async throws {
        let queue = JevLiveQueue(capacity: 1)
        let gate = QueueGate()
        let first = await queue.enqueue { await gate.hold() }
        XCTAssertTrue(first)
        await gate.waitForEntry()
        let ranSecond = expectation(description: "queued classification drains")
        let second = await queue.enqueue { ranSecond.fulfill() }
        let overflow = await queue.enqueue { XCTFail("overflow must not run") }
        XCTAssertTrue(second)
        XCTAssertFalse(overflow)
        // Network work remains blocked, but database writes do not wait for it.
        let captured = try pipeline.ingest(ClipboardEntry(content: "Captured while network waits", contentType: .text))
        XCTAssertNotNil(try database.fetch(id: try XCTUnwrap(captured.persisted.first?.id)))
        await gate.release()
        await fulfillment(of: [ranSecond], timeout: 2)
    }

    private func primarySnapshot(_ result: E2ECapturePipeline.Result) throws -> ClipboardEntry {
        let id = try XCTUnwrap(result.persisted.first?.id)
        return try XCTUnwrap(database.fetch(id: id))
    }

    private func apply(_ category: ContentType, to snapshot: ClipboardEntry) throws -> JevReclassificationService.Outcome {
        try JevReclassificationService().apply(.init(category: category), to: snapshot, database: database,
                                              configuration: configuration, detectorConfiguration: .default, extractContent: true)
    }
}

private actor DeletionRecorder {
    private(set) var ids: [UUID] = []
    func record(_ id: UUID) { ids.append(id) }
}

private actor QueueGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class ReclassificationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "offline.example" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = #"{"model":"jev-test","answers":{"content_type":{"type":"choice","choice":"prose","confidence":0.9,"probabilities":{"prose":0.9,"unknown":0.1}}}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
