#if os(macOS)
import XCTest
import PastaCore
import CloudKit
@testable import PastaSync

final class TailnetSyncTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PastaTailnetTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testPairingRequiresTargetApprovalAndAuthenticatesNodeAndSecret() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        await a.tick(); await b.tick()
        try await a.engine.requestPairing(b.device.id)
        XCTAssertTrue(try TailnetStore(database: a.db).peers().isEmpty)
        let requests = try await b.engine.snapshot().requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.device.name, "Mac 1")
        try await b.engine.approve(requests[0].id, allow: true)
        await a.tick()
        XCTAssertEqual(try a.peer(b).pairingID, try b.peer(a).pairingID)
        var request = TailnetRequest(operation: .received)
        request.entryID = UUID(); request.pairingID = try a.peer(b).pairingID
        request.token = String(repeating: "a", count: 44)
        let wrongSecret = await b.engine.handle(address: a.device.address, request: request)
        XCTAssertEqual(wrongSecret.status, "denied")
        request.token = try a.credentials.read(a.peer(b).pairingID)
        let outsideTailnet = await b.engine.handle(address: "192.168.1.3", request: request)
        XCTAssertEqual(outsideTailnet.status, "denied")
    }

    func testDeclineAndDisabledServiceCannotCreatePairing() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        await a.tick(); await b.tick()
        try await a.engine.requestPairing(b.device.id)
        let request = try await b.engine.snapshot().requests.first!
        try await b.engine.approve(request.id, allow: false)
        await a.tick()
        XCTAssertTrue(try TailnetStore(database: a.db).peers().isEmpty)
        await b.engine.setEnabled(false)
        let hello = await b.engine.handle(address: a.device.address, request: TailnetRequest(operation: .hello))
        XCTAssertEqual(hello.status, "denied")
    }

    func testDelayedPairingApprovalCannotRestoreTrustAfterDisable() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        await a.tick(); await b.tick()
        try await a.engine.requestPairing(b.device.id)
        let request = try await b.engine.snapshot().requests.first!
        try await b.engine.approve(request.id, allow: true)
        await network.pauseOnResponse(.pairingStatus)
        let polling = Task { await a.tick() }
        await network.waitForPause()
        await a.engine.setEnabled(false)
        await network.resume(); await polling.value
        let snapshot = try await a.engine.snapshot()
        XCTAssertTrue(snapshot.peers.isEmpty)
        XCTAssertEqual(snapshot.status, "Off")
        XCTAssertNil(try a.credentials.read(request.id))
        await a.engine.setEnabled(true); await a.tick()
        XCTAssertTrue(try TailnetStore(database: a.db).peers().isEmpty)
    }

    func testDelayedInitialPairingReplyCannotSurviveDisableAndReenable() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        await a.tick(); await b.tick()
        await network.pauseOnResponse(.pair)
        let requesting = Task { try await a.engine.requestPairing(b.device.id) }
        await network.waitForPause()
        let request = try await b.engine.snapshot().requests.first!
        try await b.engine.approve(request.id, allow: true)
        await a.engine.setEnabled(false)
        await a.engine.setEnabled(true); await a.tick()
        await network.resume()
        do { try await requesting.value; XCTFail("Stale pairing reply must be cancelled") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await a.tick()
        XCTAssertTrue(try TailnetStore(database: a.db).peers().isEmpty)
    }

    func testLaterPeersKeepRevocationAndPolicyChangesWhileEarlierPeerTransfers() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        let c = try await TailnetTestNode(3, network: network, parent: root)
        let d = try await TailnetTestNode(4, network: network, parent: root)
        try await a.pair(b); try await a.pair(c); try await a.pair(d)
        let entry = ClipboardEntry(content: "", contentType: .image, rawData: Data(repeating: 3, count: 300_000))
        try a.db.insert(entry)
        await network.pauseOnChunk()
        let sending = Task { await a.tick() }
        await network.waitForPause()
        try await a.engine.unpair(c.device.id)
        var policy = try a.peer(d); policy.sendEnabled = false
        try await a.engine.update(policy)
        await network.resume(); await sending.value
        XCTAssertNotNil(try b.db.fetch(id: entry.id))
        XCTAssertNil(try c.db.fetch(id: entry.id))
        XCTAssertNil(try d.db.fetch(id: entry.id))
        XCTAssertFalse(try TailnetStore(database: a.db).peers().contains { $0.id == c.device.id })
        XCTAssertFalse(try a.peer(d).sendEnabled)
    }

    func testExpiredPairingCannotBeApprovedAndRequestsAreRateLimited() async throws {
        let clock = TailnetTestClock()
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root, now: { clock.now() })
        let b = try await TailnetTestNode(2, network: network, parent: root, now: { clock.now() })
        await a.tick(); await b.tick()
        try await a.engine.requestPairing(b.device.id)
        let request = try await b.engine.snapshot().requests.first!
        do { try await a.engine.requestPairing(b.device.id); XCTFail("Repeated request must be throttled") } catch {}
        clock.advance(121)
        do { try await b.engine.approve(request.id, allow: true); XCTFail("Expired consent cannot pair") } catch {}
        XCTAssertTrue(try TailnetStore(database: b.db).peers().isEmpty)
    }

    func testDeletedLocalOriginCannotReturnThroughForwarding() throws {
        let db = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "local source", contentType: .text)
        try db.insert(entry); try db.delete(id: entry.id)
        let store = TailnetStore(database: db)
        XCTAssertTrue(try store.hasReceived(entry.id))
        XCTAssertFalse(try store.receive(entry, publishToCloud: true))
        XCTAssertEqual(try db.countEntries(), 0)
    }

    func testOnlyNewItemsThenExplicitBackfillAndClipboardPolicy() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        let old = ClipboardEntry(content: "old", contentType: .text)
        try a.db.insert(old)
        try await a.pair(b)
        XCTAssertNil(try b.db.fetch(id: old.id))
        var receiver = try b.peer(a); receiver.replaceClipboard = true
        try await b.engine.update(receiver)
        // Deliberately use an old timestamp: sequence, not clocks, establishes newness.
        let fresh = ClipboardEntry(content: "new", contentType: .text, timestamp: .distantPast)
        try a.db.insert(fresh)
        await a.tick()
        XCTAssertEqual(try b.db.fetch(id: fresh.id)?.content, "new")
        XCTAssertEqual(try b.db.unsyncedCount(), 0)
        XCTAssertFalse(try XCTUnwrap(b.db.fetch(id: fresh.id)).cloudSyncAllowed)
        let writes = await network.clipboardWrites[b.device.id]
        XCTAssertEqual(writes, [fresh.id])
        try await a.engine.backfill(b.device.id)
        await a.tick()
        XCTAssertEqual(try b.db.fetch(id: old.id)?.content, "old")
        let writesAfterBackfill = await network.clipboardWrites[b.device.id]
        XCTAssertEqual(writesAfterBackfill, [fresh.id])
    }

    func testOnwardCloudPolicyPreservesProvenanceWithoutNewCloudFields() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        var peer = try b.peer(a); peer.publishToCloud = true
        try await b.engine.update(peer)
        let entry = ClipboardEntry(content: "bridge me", contentType: .apiKey, metadata: "{\"test\":true}")
        try a.db.insert(entry)
        await a.tick()
        let received = try XCTUnwrap(b.db.fetch(id: entry.id))
        XCTAssertTrue(received.receivedViaTailnet)
        XCTAssertEqual(try b.db.fetchUnsynced().map(\.id), [entry.id])
        let mapper = RecordMapper()
        let record = try mapper.preparedRecord(from: received, zoneID: CKRecordZone.ID(zoneName: "Test", ownerName: CKCurrentUserDefaultName))
        defer { record.cleanupTemporaryAsset() }
        let cloudCopy = try XCTUnwrap(mapper.entry(from: record.record))
        XCTAssertTrue(cloudCopy.receivedViaTailnet)
        XCTAssertEqual(cloudCopy.metadata, entry.metadata)
        let otherAccountDevice = try DatabaseManager.inMemory()
        try otherAccountDevice.applySyncChanges(modified: [cloudCopy], deleted: [])
        XCTAssertTrue(try XCTUnwrap(otherAccountDevice.fetch(id: entry.id)).receivedViaTailnet)
    }

    func testForwardingOptInCyclesAndDeletionReceiptsSurviveDatabaseRestart() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        let c = try await TailnetTestNode(3, network: network, parent: root)
        try await a.pair(b); try await b.pair(c); try await c.pair(a)
        let entry = ClipboardEntry(content: "loop test", contentType: .text)
        // Pause A→C so receipt must take the explicitly forwarded route.
        var direct = try a.peer(c); direct.sendEnabled = false; try await a.engine.update(direct)
        try a.db.insert(entry)
        await a.tick(); await b.tick()
        XCTAssertNil(try c.db.fetch(id: entry.id))
        var forward = try b.peer(c); forward.forwardReceived = true; try await b.engine.update(forward)
        try await b.engine.backfill(c.device.id)
        await b.tick()
        XCTAssertNotNil(try c.db.fetch(id: entry.id))
        var back = try c.peer(a); back.forwardReceived = true; try await c.engine.update(back)
        try await c.engine.backfill(a.device.id); await c.tick()
        XCTAssertEqual(try a.db.countEntries(), 1)
        XCTAssertEqual(try a.db.fetch(id: entry.id)?.copyCount, 1)
        try b.db.delete(id: entry.id)
        let reopened = try DatabaseManager(databaseURL: b.root.appendingPathComponent("history.sqlite"))
        XCTAssertTrue(try TailnetStore(database: reopened).hasReceived(entry.id))
        XCTAssertFalse(try TailnetStore(database: reopened).receive(entry, publishToCloud: true))
        XCTAssertNil(try reopened.fetch(id: entry.id))
    }

    func testOfflineCatchupAndUnpairKeepsExistingHistoryButStopsBothDirections() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        await network.setOffline(b.device.id, true)
        let entry = ClipboardEntry(content: "while offline", contentType: .text)
        try a.db.insert(entry); await a.tick()
        XCTAssertNil(try b.db.fetch(id: entry.id))
        await network.setOffline(b.device.id, false)
        await a.tick()
        XCTAssertNotNil(try b.db.fetch(id: entry.id))
        try await a.engine.unpair(b.device.id)
        XCTAssertTrue(try TailnetStore(database: a.db).peers().isEmpty)
        XCTAssertTrue(try TailnetStore(database: b.db).peers().isEmpty)
        XCTAssertNotNil(try b.db.fetch(id: entry.id))
        let second = ClipboardEntry(content: "after revoke", contentType: .text)
        try a.db.insert(second); await a.tick()
        XCTAssertNil(try b.db.fetch(id: second.id))
    }

    func testLargeSelectionApprovalIsBoundToCurrentPayloadAndIndependentReceiverLimit() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        var policy = try a.peer(b); policy.approvalBytes = 10; try await a.engine.update(policy)
        let source = root.appendingPathComponent("document.txt")
        try Data(repeating: 7, count: 20).write(to: source)
        let entry = ClipboardEntry(content: source.path, contentType: .filePath)
        try a.db.insert(entry); await a.tick()
        var approvals = try await a.engine.snapshot().transfers.filter { $0.state == .approval }
        XCTAssertEqual(approvals.count, 1)
        let zeroChunks = await network.chunks
        XCTAssertEqual(zeroChunks, 0)
        try await a.engine.decideTransfer(approvals[0], approve: true)
        try Data(repeating: 8, count: 21).write(to: source)
        await a.tick()
        let revised = try await a.engine.snapshot().transfers.filter { $0.state == .approval }
        XCTAssertEqual(revised.count, 1)
        XCTAssertNotEqual(revised[0].approvedDigest, approvals[0].approvedDigest)
        approvals = revised
        try await a.engine.decideTransfer(approvals[0], approve: true)
        var receivePolicy = try b.peer(a); receivePolicy.receiveLimitBytes = 15; try await b.engine.update(receivePolicy)
        await a.tick()
        XCTAssertNil(try b.db.fetch(id: entry.id))
        let failures = try await a.engine.snapshot().transfers.filter { $0.state == .failed }
        XCTAssertEqual(failures.count, 1)
        receivePolicy.receiveLimitBytes = 100; receivePolicy.publishToCloud = true; try await b.engine.update(receivePolicy)
        try await a.engine.retry(failures[0]); await a.tick()
        let received = try XCTUnwrap(b.db.fetch(id: entry.id))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: received.filePaths[0])), Data(repeating: 8, count: 21))
        XCTAssertFalse(received.allowsCloudUpload)
        XCTAssertEqual(try b.db.unsyncedCount(), 0)
    }

    func testInterruptedChunksResumeAndHeldFilesFollowRetentionWithoutDeletingOriginals() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        let source = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let data = Data(repeating: 9, count: 600_000)
        try data.write(to: source.appendingPathComponent("file\nwith newline.bin"))
        let entry = ClipboardEntry(content: source.path, contentType: .filePath, rawData: try JSONEncoder().encode([source.path]))
        try a.db.insert(entry)
        await network.interrupt(after: 1); await a.tick()
        XCTAssertNil(try b.db.fetch(id: entry.id))
        await network.interrupt(after: nil); await a.tick()
        let received = try XCTUnwrap(b.db.fetch(id: entry.id))
        let folder = URL(fileURLWithPath: received.filePaths[0])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("file\nwith newline.bin")), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("empty").path))
        try b.db.delete(id: entry.id); await b.engine.setEnabled(false); await b.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUnpairWhileAChunkIsInFlightPreventsHistoryCommit() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        let entry = ClipboardEntry(content: "", contentType: .image, rawData: Data(repeating: 1, count: 600_000))
        try a.db.insert(entry)
        await network.pauseOnChunk()
        let sending = Task { await a.tick() }
        await network.waitForPause()
        try await a.engine.unpair(b.device.id)
        await network.resume()
        await sending.value
        XCTAssertNil(try b.db.fetch(id: entry.id))
        XCTAssertTrue(try TailnetStore(database: a.db).peers().isEmpty)
        XCTAssertTrue(try TailnetStore(database: b.db).peers().isEmpty)
    }

    func testTurningOffDuringTransferStopsBeforeCommitAndResumesWhenReenabled() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        let entry = ClipboardEntry(content: "", contentType: .image, rawData: Data(repeating: 2, count: 600_000))
        try a.db.insert(entry)
        await network.pauseOnChunk()
        let sending = Task { await a.tick() }
        await network.waitForPause()
        await a.engine.setEnabled(false)
        await network.resume(); await sending.value
        XCTAssertNil(try b.db.fetch(id: entry.id))
        await a.engine.setEnabled(true); await a.tick()
        XCTAssertEqual(try b.db.fetch(id: entry.id)?.rawData, entry.rawData)
    }

    func testLaterLocalEditsAndPinsDoNotOverwriteDeliveredPeerContent() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        var entry = ClipboardEntry(content: "first version", contentType: .text)
        try a.db.insert(entry); await a.tick()
        try b.db.setPinned(id: entry.id, pinned: true)
        entry.content = "later version"; entry.copyCount = 99
        try a.db.applySyncChanges(modified: [entry], deleted: [])
        try await a.engine.backfill(b.device.id); await a.tick()
        let received = try XCTUnwrap(b.db.fetch(id: entry.id))
        XCTAssertEqual(received.content, "first version")
        XCTAssertEqual(received.copyCount, 1)
        XCTAssertTrue(received.isPinned)
    }

    func testImageAndRichTextBytesRoundTripAndMissingFileDoesNotBlockText() async throws {
        let network = TailnetTestNetwork()
        let a = try await TailnetTestNode(1, network: network, parent: root)
        let b = try await TailnetTestNode(2, network: network, parent: root)
        try await a.pair(b)
        let missing = ClipboardEntry(content: root.appendingPathComponent("missing").path, contentType: .filePath)
        let rtf = ClipboardEntry(content: "hello", contentType: .text, rawData: Data("{\\rtf1 hello}".utf8))
        let image = ClipboardEntry(content: "", contentType: .image, rawData: Data(repeating: 0x44, count: 500_000))
        try a.db.insert(missing); try a.db.insert(rtf); try a.db.insert(image)
        await a.tick()
        XCTAssertEqual(try b.db.fetch(id: rtf.id)?.rawData, rtf.rawData)
        XCTAssertEqual(try b.db.fetch(id: image.id)?.rawData, image.rawData)
        XCTAssertNil(try b.db.fetch(id: missing.id))
        let failures = try await a.engine.snapshot().transfers.filter { $0.state == .failed }
        XCTAssertEqual(failures.map(\.id), [missing.id])
    }
}
private final class TailnetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}
#endif
