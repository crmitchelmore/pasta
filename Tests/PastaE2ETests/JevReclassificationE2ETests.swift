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

    func testProvidersApplyCustomChoicesKeepEmbeddedItemsAndHonourExtractionLimits() throws {
        let custom = DecisionClassifierDefinition(name: "Customer ID", description: "A customer reference", contentType: .text)
        for provider in RemoteClassificationProvider.allCases {
            let snapshot = try database.insert(ClipboardEntry(content: "CUST-\(UUID())", contentType: .prose,
                                                               cloudSyncAllowed: false, receivedViaTailnet: true), deduplicate: false).entry
            let configuration = JevConfiguration(isEnabled: true, provider: provider, mode: .primary,
                                                 rules: .init(customClassifiers: [custom]))
            let outcome = try JevReclassificationService().apply(.init(category: .text, rawChoice: custom.choiceID),
                to: snapshot, database: database, configuration: configuration, detectorConfiguration: .default,
                extractContent: true, skipAPIKeys: true)
            XCTAssertEqual(outcome, .applied)
            let stored = try XCTUnwrap(database.fetch(id: snapshot.id))
            XCTAssertEqual(stored.contentType, .text)
            XCTAssertEqual(stored.content, snapshot.content)
            XCTAssertFalse(stored.cloudSyncAllowed)
            XCTAssertTrue(stored.receivedViaTailnet)
            let metadata = try XCTUnwrap(e2eJSONDictionary(stored.metadata)?["decisionClassification"] as? [String: String])
            XCTAssertEqual(metadata["label"], "Customer ID")
            XCTAssertEqual(metadata["provider"], provider.rawValue)
            let reopened = try environment.openDatabase()
            XCTAssertEqual(try reopened.fetch(id: snapshot.id)?.metadata, stored.metadata)
            let normalResult = try JevReclassificationService().apply(.init(category: .prose), to: stored,
                database: database, configuration: configuration, detectorConfiguration: .default,
                extractContent: false, skipAPIKeys: true)
            XCTAssertEqual(normalResult, .applied)
            XCTAssertNil(e2eJSONDictionary(try database.fetch(id: snapshot.id)?.metadata)?["decisionClassification"])
        }

        // Retyping mixed text as code keeps its embedded items with either provider.
        for provider in RemoteClassificationProvider.allCases {
            let configuration = JevConfiguration(isEnabled: true, provider: provider, mode: .primary)
            let result = try pipeline.ingest(ClipboardEntry(content: "Contact a@example.com and visit https://example.com", contentType: .text))
            let snapshot = try primarySnapshot(result)
            let outcome = try JevReclassificationService().apply(.init(category: .code), to: snapshot,
                database: database, configuration: configuration, detectorConfiguration: .default,
                extractContent: true, skipAPIKeys: true)
            XCTAssertEqual(outcome, .applied)
            let updated = try XCTUnwrap(database.fetch(id: snapshot.id))
            XCTAssertEqual(updated.contentType, .code)
            XCTAssertTrue(updated.isMixedContent)
            XCTAssertEqual(Set(try database.fetchExtractedEntries(parentId: snapshot.id).map(\.content)),
                           ["a@example.com", "https://example.com"])
        }

        // Configured extraction limits reach capture and both providers.
        let content = (0..<125).map { "person\($0)@example.com" }.joined(separator: "\n")
        pipeline.extractionConfiguration = try .init(maximumSavedItems: 25)
        let capture = try pipeline.ingest(ClipboardEntry(content: content, contentType: .text,
                                                        cloudSyncAllowed: false, receivedViaTailnet: true))
        let original = try primarySnapshot(capture)
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: original.id).count, 25)
        for provider in RemoteClassificationProvider.allCases {
            for limit in [1, 0] {
                let snapshot = try XCTUnwrap(database.fetch(id: original.id))
                let configuration = JevConfiguration(isEnabled: true, provider: provider, mode: .primary)
                let outcome = try JevReclassificationService().apply(.init(category: .code), to: snapshot,
                    database: database, configuration: configuration, detectorConfiguration: .default,
                    extractContent: true, skipAPIKeys: true, extractionConfiguration: try .init(maximumSavedItems: limit))
                XCTAssertEqual(outcome, .applied)
                let children = try database.fetchExtractedEntries(parentId: original.id)
                XCTAssertEqual(children.count, limit == 0 ? 125 : 1)
                XCTAssertTrue(children.allSatisfy { !$0.cloudSyncAllowed && $0.receivedViaTailnet })
            }
        }
    }

    func testRetainedOutcomesLeaveSensitiveBinaryFileAndUnknownEntriesUntouched() throws {
        // Microsoft history reclassification keeps sensitive and binary items local.
        let microsoft = JevConfiguration(isEnabled: true, provider: .microsoftDecision, mode: .primary)
        for type in [ContentType.apiKey, .jwt, .creditCard, .iban, .envVar, .image, .screenshot, .filePath] {
            let entry = try database.insert(ClipboardEntry(content: "Private \(type.rawValue)", contentType: type), deduplicate: false).entry
            let snapshot = try XCTUnwrap(database.fetch(id: entry.id))
            let outcome = try JevReclassificationService().apply(.init(category: .prose), to: snapshot,
                database: database, configuration: microsoft, detectorConfiguration: .default,
                extractContent: true, skipAPIKeys: true)
            XCTAssertEqual(outcome, .retained, "\(type)")
            XCTAssertEqual(try database.fetch(id: snapshot.id), snapshot)
        }

        // File pastes and secrets cannot be retyped without consent.
        let file = ClipboardEntry(content: "/tmp/report.txt", contentType: .filePath, rawData: Data("file".utf8))
        _ = try database.insert(file, deduplicate: false)
        let storedFile = try XCTUnwrap(database.fetch(id: file.id))
        XCTAssertEqual(try apply(.prose, to: storedFile), .retained)
        XCTAssertEqual(try database.fetch(id: file.id), storedFile)
        let secret = ClipboardEntry(content: "mock-key", contentType: .apiKey)
        let storedSecret = try database.insert(secret, deduplicate: false).entry
        XCTAssertEqual(try apply(.text, to: storedSecret), .retained)
        XCTAssertEqual(try database.fetch(id: secret.id)?.contentType, .apiKey)

        // "unknown" keeps the original category and children.
        let unknown = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: "Read https://example.com before the launch.", contentType: .text)))
        let unknownChildren = try database.fetchExtractedEntries(parentId: unknown.id)
        XCTAssertEqual(try apply(.unknown, to: unknown), .retained)
        XCTAssertEqual(try database.fetch(id: unknown.id), unknown)
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: unknown.id), unknownChildren)

        // The API-key exclusion holds even with sensitive-upload consent.
        let syntheticKey = "ghp_" + "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2"
        let entry = ClipboardEntry(content: "Read https://example.com and use \(syntheticKey) for this demonstration.", contentType: .text)
        var snapshot = try database.insert(entry, deduplicate: false).entry
        var optedIn = configuration
        optedIn.includeSensitiveContent = true
        let service = JevReclassificationService()
        XCTAssertEqual(try service.apply(.init(category: .prose), to: snapshot, database: database,
                                         configuration: optedIn, detectorConfiguration: .default,
                                         extractContent: true, skipAPIKeys: false), .applied)
        XCTAssertTrue(try database.fetchExtractedEntries(parentId: snapshot.id).contains { $0.contentType == .apiKey })
        snapshot = try XCTUnwrap(database.fetch(id: snapshot.id))
        XCTAssertEqual(try service.apply(.init(category: .prose), to: snapshot, database: database,
                                         configuration: optedIn, detectorConfiguration: .default,
                                         extractContent: true, skipAPIKeys: true), .applied)
        let children = try database.fetchExtractedEntries(parentId: snapshot.id)
        XCTAssertFalse(children.contains { $0.contentType == .apiKey })
        XCTAssertTrue(children.contains { $0.contentType == .url })
        snapshot = try XCTUnwrap(database.fetch(id: snapshot.id))
        XCTAssertEqual(try service.apply(.init(category: .apiKey), to: snapshot, database: database,
                                         configuration: optedIn, detectorConfiguration: .default,
                                         extractContent: true, skipAPIKeys: true), .retained)
        XCTAssertEqual(try database.fetch(id: snapshot.id), snapshot)

        // The summary separates retained entries from provider failures.
        XCTAssertEqual(JevReclassificationService.applicationSummary(total: 5, updated: 1, changedDeleted: 1, providerFailures: 2),
                       "1 updated · 1 retained · 1 changed/deleted · 2 provider failures.")
        XCTAssertEqual(JevReclassificationService.applicationSummary(total: 5, updated: 0, changedDeleted: 0, providerFailures: 1),
                       "0 updated · 4 retained · 0 changed/deleted · 1 provider failures.")
    }

    func testReclassifyingCanonicalDedupRowRebuildsChildrenAndPreservesConsent() throws {
        // The persisted dedup identity is reclassified without losing content, pins or counts.
        let capture = ClipboardEntry(content: "A short title", contentType: .text, isPinned: true)
        let first = try pipeline.ingest(capture)
        let recopy = ClipboardEntry(content: capture.content, contentType: .text)
        let second = try pipeline.ingest(recopy)
        let snapshot = try primarySnapshot(second)
        XCTAssertEqual(snapshot.id, first.persisted.first?.id)
        XCTAssertNotEqual(snapshot.id, recopy.id)
        XCTAssertEqual(snapshot.copyCount, 2)

        XCTAssertEqual(try apply(.prose, to: snapshot), .applied)
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

        // A category change rebuilds children and keeps the parent's sharing consent.
        let text = "Read https://example.com and ask team@example.com for the launch notes."
        let mixed = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: text, contentType: .text,
                                                                      cloudSyncAllowed: false, receivedViaTailnet: true)))
        let oldIDs = Set(try database.fetchExtractedEntries(parentId: mixed.id).map(\.id))
        XCTAssertFalse(oldIDs.isEmpty)
        XCTAssertEqual(try apply(.prose, to: mixed), .applied)
        let children = try database.fetchExtractedEntries(parentId: mixed.id)
        XCTAssertFalse(children.isEmpty)
        XCTAssertTrue(Set(children.map(\.id)).isDisjoint(with: oldIDs))
        XCTAssertTrue(children.allSatisfy { !$0.cloudSyncAllowed && $0.receivedViaTailnet && !$0.isSynced })
        XCTAssertEqual(try database.fetch(id: mixed.id)?.cloudSyncAllowed, false)
        let changed = try XCTUnwrap(database.fetch(id: mixed.id))
        XCTAssertEqual(try apply(.url, to: changed), .applied)
        let retypedChildren = try database.fetchExtractedEntries(parentId: mixed.id)
        XCTAssertEqual(Set(retypedChildren.map(\.content)), Set(children.map(\.content)))
        XCTAssertTrue(try XCTUnwrap(database.fetch(id: mixed.id)).isMixedContent)
    }

    func testStaleSnapshotsAndInvalidChildrenCannotOverwriteNewerState() throws {
        // An invalid extracted parent rolls back the classification and child retirement.
        let mixed = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: "Read https://example.com before the launch.", contentType: .text)))
        let children = try database.fetchExtractedEntries(parentId: mixed.id)
        let invalidChild = ClipboardEntry(content: "https://example.com", contentType: .url, parentEntryId: UUID())
        XCTAssertThrowsError(try database.applyClassification(matching: mixed, contentType: .prose,
                                                              metadata: nil, extractedEntries: [invalidChild]))
        XCTAssertEqual(try database.fetch(id: mixed.id), mixed)
        XCTAssertEqual(try database.fetchExtractedEntries(parentId: mixed.id), children)
        XCTAssertTrue(try database.pendingClassificationDeletions().isEmpty)

        // A changed or deleted snapshot cannot be overwritten or resurrected.
        let snapshot = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: "Original title", contentType: .text)))
        XCTAssertTrue(try database.applyClassification(matching: snapshot, contentType: .code, metadata: nil, extractedEntries: []))
        XCTAssertEqual(try apply(.prose, to: snapshot), .changedSinceRequest)
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.contentType, .code)
        try database.delete(id: snapshot.id)
        XCTAssertEqual(try apply(.prose, to: snapshot), .changedSinceRequest)
        XCTAssertNil(try database.fetch(id: snapshot.id))

        // A stale upload cannot mark the newer classification synced.
        let titled = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: "A title", contentType: .text)))
        XCTAssertEqual(try apply(.prose, to: titled), .applied)
        let updated = try XCTUnwrap(database.fetch(id: titled.id))
        try database.markSynced(matching: [updated])
        XCTAssertEqual(try database.fetch(id: titled.id)?.isSynced, true)
        try database.markSynced(matching: [titled])
        XCTAssertEqual(try database.fetch(id: titled.id)?.isSynced, false)

        // Upload acknowledgement tolerates the database's timestamp precision.
        let precise = ClipboardEntry(content: "Timestamp precision", contentType: .text,
                                     timestamp: Date(timeIntervalSince1970: 1_700_000_000.123456))
        let outcome = try database.insert(precise, deduplicate: false)
        try database.markSynced(matching: [outcome.entry])
        XCTAssertEqual(try database.fetch(id: precise.id)?.isSynced, true)
    }

    func testCloudReplayAndBackfillCannotResurrectRetiredChildrenOrHideNewerClassification() async throws {
        // Backfill detects a classification that changed while uploading.
        let pending = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: "Pending title", contentType: .text)))
        let db = try XCTUnwrap(database)
        do {
            _ = try await db.backfillUnsynced { entries, confirm in
                _ = try db.applyClassification(matching: pending, contentType: .prose, metadata: nil, extractedEntries: [])
                confirm(entries.map(\.id))
                return entries.count
            }
            XCTFail("Stale upload must leave newer classification pending")
        } catch let error as PendingSyncUploadsError {
            XCTAssertEqual(error.count, 1)
        }
        XCTAssertEqual(try db.fetch(id: pending.id)?.contentType, .prose)
        XCTAssertEqual(try db.fetch(id: pending.id)?.isSynced, false)

        // Retired children stay deleted through cloud replay and deletion upload.
        let snapshot = try primarySnapshot(pipeline.ingest(ClipboardEntry(content: "Read https://example.com and ask team@example.com for the launch notes.", contentType: .text)))
        let oldChildren = try database.fetchExtractedEntries(parentId: snapshot.id)
        XCTAssertFalse(oldChildren.isEmpty)
        XCTAssertEqual(try JevReclassificationService().apply(.init(category: .url), to: snapshot, database: database,
            configuration: configuration, detectorConfiguration: .default, extractContent: false, skipAPIKeys: false), .applied)
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
        XCTAssertEqual(try database.fetch(id: pending.id)?.isSynced, true, "the earlier pending classification uploads once confirmed")
        // Even a delayed pull fetched before the deletion cannot resurrect a child.
        try database.applySyncChanges(modified: oldChildren, deleted: [])
        XCTAssertTrue(try database.fetchExtractedEntries(parentId: snapshot.id).isEmpty)
        try database.applySyncChanges(modified: [], deleted: oldChildren.map(\.id))
        XCTAssertTrue(try database.pendingClassificationDeletions().isEmpty)
        let reopened = try environment.openDatabase()
        // A stale writer can recreate the record even after its deletion was acknowledged.
        try reopened.applySyncChanges(modified: oldChildren, deleted: [])
        XCTAssertTrue(try reopened.fetchExtractedEntries(parentId: snapshot.id).isEmpty)
        XCTAssertEqual(Set(try reopened.pendingClassificationDeletions()), Set(oldChildren.map(\.id)))

        // A failed child deletion stays durable and blocks the pull backfill
        // (a fresh store, so the stale-writer tombstones above do not mix in).
        let offline = try E2ETempEnvironment(name: "jev-offline")
        defer { offline.destroy() }
        let offlineDB = try offline.openDatabase()
        let offlinePipeline = E2ECapturePipeline(database: offlineDB, imageStorage: try offline.openImageStorage(), detector: ContentTypeDetector())
        let offlineResult = try offlinePipeline.ingest(ClipboardEntry(content: "Read https://example.com and ask team@example.com for the launch notes.", contentType: .text))
        let offlineSnapshot = try XCTUnwrap(offlineDB.fetch(id: try XCTUnwrap(offlineResult.persisted.first?.id)))
        let offlineChildren = try offlineDB.fetchExtractedEntries(parentId: offlineSnapshot.id)
        XCTAssertFalse(offlineChildren.isEmpty)
        XCTAssertEqual(try JevReclassificationService().apply(.init(category: .url), to: offlineSnapshot, database: offlineDB,
            configuration: configuration, detectorConfiguration: .default, extractContent: false, skipAPIKeys: false), .applied)
        do {
            _ = try await offlineDB.backfillUnsynced(deleting: { _ in throw URLError(.notConnectedToInternet) }) { _, _ in
                XCTFail("Uploads cannot run while deletions are unconfirmed")
                return 0
            }
            XCTFail("Offline deletion must fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let reopenedOffline = try offline.openDatabase()
        XCTAssertEqual(Set(try reopenedOffline.pendingClassificationDeletions()), Set(offlineChildren.map(\.id)))
        try reopenedOffline.applySyncChanges(modified: offlineChildren, deleted: [])
        XCTAssertTrue(try reopenedOffline.fetchExtractedEntries(parentId: offlineSnapshot.id).isEmpty)
    }

    func testProviderOutageAndBoundedLiveQueueNeverBlockDurableCapture() async throws {
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
                                                             extractContent: true, skipAPIKeys: false), .applied)
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.content, snapshot.content)
        XCTAssertEqual(try database.fetch(id: snapshot.id)?.contentType, .prose)

        // The live queue is bounded, and capture does not wait on it.
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
                                              configuration: configuration, detectorConfiguration: .default, extractContent: true, skipAPIKeys: false)
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
