import CloudKit
import Combine
import Foundation
import GRDB
import XCTest
@testable import PastaCore
@testable import PastaSync

final class SyncPullServiceTests: XCTestCase {
    func testDatabaseFailureRollsBackBatchAndKeepsTokenForRetry() async throws {
        let database = try DatabaseManager.inMemory()
        let original = ClipboardEntry(
            content: "aardvark original", contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1_000), copyCount: 7
        )
        let deleted = ClipboardEntry(
            content: "protected deletion", contentType: .text, timestamp: Date(timeIntervalSince1970: 2_000)
        )
        try database.insertBatch([original, deleted])
        let updated = ClipboardEntry(id: original.id, content: "pangolin replacement", contentType: .text)
        let added = ClipboardEntry(content: "new arrival", contentType: .text)
        let remote = PullTestRemote(batches: [SyncChangeBatch(
            modified: [updated, added], deleted: [deleted.id], token: Data([1])
        )])
        let service = makeService(remote)
        try database.applySyncChanges(modified: [], deleted: [], checkpoint: Data([0]))
        try await database.dbWriter.write { connection in
            try connection.execute(sql: """
                CREATE TRIGGER reject_sync_delete BEFORE DELETE ON clipboard_entries
                WHEN old.id = '\(deleted.id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'injected sync apply failure'); END;
                """)
        }

        do {
            try await service.pull(into: database)
            XCTFail("A failed database transaction must fail the pull")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }
        let failedState = await remote.snapshot()
        XCTAssertEqual(failedState.token, Data([0]))
        XCTAssertEqual(failedState.acknowledgements, [])
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([0]))
        XCTAssertEqual(try database.fetch(id: original.id), original)
        XCTAssertEqual(try database.fetch(id: deleted.id), deleted)
        XCTAssertNil(try database.fetch(id: added.id))
        XCTAssertEqual(try database.searchFTS(query: "aardvark", contentType: nil).map(\.id), [original.id])
        XCTAssertTrue(try database.searchFTS(query: "pangolin", contentType: nil).isEmpty)

        try await database.dbWriter.write { try $0.execute(sql: "DROP TRIGGER reject_sync_delete") }
        try await service.pull(into: database)

        let retriedState = await remote.snapshot()
        XCTAssertEqual(retriedState.fetchTokens, [Data([0]), Data([0])])
        XCTAssertEqual(retriedState.token, Data([1]))
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([1]))
        XCTAssertEqual(try database.countEntries(), 2)
        XCTAssertEqual(try database.fetch(id: original.id)?.content, updated.content)
        XCTAssertNotNil(try database.fetch(id: added.id))
        XCTAssertNil(try database.fetch(id: deleted.id))
        XCTAssertEqual(try database.unsyncedCount(), 0)
    }

    func testAcknowledgementFailureReplaysWithoutDuplicatesOrCopyCountInflation() async throws {
        let database = try DatabaseManager.inMemory()
        let local = ClipboardEntry(
            content: "same content", contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1_000), copyCount: 9
        )
        let downloaded = ClipboardEntry(content: local.content, contentType: .text, copyCount: 4)
        try database.insert(local)
        let remote = PullTestRemote(batches: [SyncChangeBatch(
            modified: [downloaded], deleted: [], token: Data([1])
        )], acknowledgementFailures: 1)
        let service = makeService(remote)

        do {
            try await service.pull(into: database)
            XCTFail("Acknowledgement failure must be surfaced")
        } catch {
            XCTAssertEqual(error as? PullTestError, .acknowledgement)
        }
        let failedState = await remote.snapshot()
        XCTAssertEqual(failedState.token, Data([0]))
        XCTAssertEqual(try database.fetch(id: downloaded.id)?.copyCount, 4)
        XCTAssertEqual(try database.countEntries(), 2, "The database commits before acknowledgement")
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([1]),
                       "The committed cursor belongs to the same transaction as its rows")

        try await service.pull(into: database)

        let retriedState = await remote.snapshot()
        XCTAssertEqual(retriedState.fetchTokens, [Data([0]), Data([0])])
        XCTAssertEqual(retriedState.acknowledgements, [Data([1]), Data([1])])
        XCTAssertEqual(retriedState.token, Data([1]))
        XCTAssertEqual(try database.countEntries(), 2)
        XCTAssertEqual(try database.fetch(id: downloaded.id)?.copyCount, 4)
        XCTAssertEqual(try database.fetch(id: downloaded.id)?.isSynced, true)
        XCTAssertEqual(try database.fetch(id: local.id), local)
        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [local.id])
    }

    func testFetchFailureLeavesDatabaseAndTokenUntouched() async throws {
        let database = try DatabaseManager.inMemory()
        let local = ClipboardEntry(
            content: "local stays intact", contentType: .text, timestamp: Date(timeIntervalSince1970: 1_000)
        )
        try database.insert(local)
        let remote = PullTestRemote(batches: [], fetchFailures: 1)

        do {
            try await makeService(remote).pull(into: database)
            XCTFail("Fetch failure must be surfaced")
        } catch {
            XCTAssertEqual(error as? PullTestError, .fetch)
        }

        let state = await remote.snapshot()
        XCTAssertEqual(state.token, Data([0]))
        XCTAssertTrue(state.acknowledgements.isEmpty)
        XCTAssertEqual(try database.countEntries(), 1)
        XCTAssertEqual(try database.fetch(id: local.id), local)
    }

    func testOverlappingPullIsRejectedAndCannotRegressRowsOrToken() async throws {
        let database = try DatabaseManager.inMemory()
        let original = ClipboardEntry(content: "older response", contentType: .text)
        let updated = ClipboardEntry(id: original.id, content: "newer response", contentType: .text)
        let remote = PullTestRemote(batches: [
            SyncChangeBatch(modified: [original], deleted: [], token: Data([1])),
            SyncChangeBatch(modified: [updated], deleted: [], token: Data([2]))
        ])
        let enteredFetch = expectation(description: "first pull entered fetch")
        let gate = PullTestGate()
        let service = SyncPullService(fetch: { _ in
            await gate.wait { enteredFetch.fulfill() }
            return try await remote.fetch()
        }, acknowledge: { try await remote.acknowledge($0) })
        let first = Task { try await service.pull(into: database) }
        await fulfillment(of: [enteredFetch], timeout: 2)

        do {
            try await service.pull(into: database)
            XCTFail("Overlapping pulls must not start another fetch")
        } catch SyncPullService.PullError.alreadyInProgress {
            // The first suspended fetch still owns the entire pull transaction.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await gate.open()
        try await first.value
        // The gate remains open; the next pull may safely advance the cursor.
        try await service.pull(into: database)

        let state = await remote.snapshot()
        XCTAssertEqual(state.fetchTokens, [Data([0]), Data([1])])
        XCTAssertEqual(state.acknowledgements, [Data([1]), Data([2])])
        XCTAssertEqual(state.token, Data([2]))
        XCTAssertEqual(try database.fetch(id: original.id)?.content, updated.content)
        XCTAssertEqual(try database.countEntries(), 1)
    }

    func testCancellationDuringFetchKeepsTokenAndAllowsRetry() async throws {
        let database = try DatabaseManager.inMemory()
        let downloaded = ClipboardEntry(content: "retry after cancellation", contentType: .text)
        let remote = PullTestRemote(batches: [SyncChangeBatch(
            modified: [downloaded], deleted: [], token: Data([1])
        )])
        let enteredFetch = expectation(description: "pull entered fetch")
        let gate = PullTestGate()
        let service = SyncPullService(fetch: { _ in
            await gate.wait { enteredFetch.fulfill() }
            return try await remote.fetch()
        }, acknowledge: { try await remote.acknowledge($0) })
        let pull = Task { try await service.pull(into: database) }
        await fulfillment(of: [enteredFetch], timeout: 2)
        pull.cancel()
        await gate.open()

        do {
            try await pull.value
            XCTFail("A cancelled pull must fail before applying or acknowledging")
        } catch is CancellationError {
        }
        let cancelledState = await remote.snapshot()
        XCTAssertEqual(cancelledState.token, Data([0]))
        XCTAssertTrue(cancelledState.acknowledgements.isEmpty)
        XCTAssertEqual(try database.countEntries(), 0)

        try await service.pull(into: database)
        let retriedState = await remote.snapshot()
        XCTAssertEqual(retriedState.token, Data([1]))
        XCTAssertEqual(try database.fetch(id: downloaded.id)?.content, downloaded.content)
    }

    @MainActor
    func testResetCannotClearDatabaseCheckpointDuringPull() async throws {
        let database = try DatabaseManager.inMemory()
        try database.applySyncChanges(modified: [], deleted: [], checkpoint: Data([1]))
        let enteredFetch = expectation(description: "manager pull entered fetch")
        let gate = PullTestGate()
        let service = SyncPullService(fetch: { checkpoint in
            XCTAssertEqual(checkpoint, Data([1]))
            await gate.wait { enteredFetch.fulfill() }
            return SyncChangeBatch(modified: [], deleted: [], token: Data([2]))
        })
        let manager = SyncManager(pullService: service)
        let pull = Task { try await manager.pullChanges(into: database) }
        await fulfillment(of: [enteredFetch], timeout: 2)

        try manager.resetSync(in: database)
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([1]))
        await gate.open()
        try await pull.value
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([2]))

        try manager.resetSync(in: database)
        XCTAssertNil(try database.loadSyncChangeToken())
    }

    @MainActor
    func testManagerPublishesFailureWithoutAdvancingLastSyncDate() async throws {
        let database = try DatabaseManager.inMemory()
        let remote = PullTestRemote(batches: [], fetchFailures: 1)
        let manager = SyncManager(pullService: makeService(remote))
        let previousDate = manager.lastSyncDate
        var states: [SyncManager.SyncState] = []
        let observation = manager.$syncState.sink { states.append($0) }
        defer { observation.cancel() }

        do {
            try await manager.pullChanges(into: database)
            XCTFail("The manager must propagate the failed pull")
        } catch {
            XCTAssertEqual(error as? PullTestError, .fetch)
        }

        XCTAssertEqual(states, [.idle, .syncing, .error(PullTestError.fetch.localizedDescription)])
        XCTAssertEqual(manager.lastSyncDate, previousDate)
        XCTAssertEqual(manager.syncedEntryCount, 0)
        XCTAssertEqual(try database.countEntries(), 0)
    }

    @MainActor
    func testManagerPublishesErrorWhenSyncTransportIsUnavailable() async throws {
        let database = try DatabaseManager.inMemory()
        let manager = SyncManager(syncEnabled: false)
        let previousDate = manager.lastSyncDate
        var states: [SyncManager.SyncState] = []
        let observation = manager.$syncState.sink { states.append($0) }
        defer { observation.cancel() }

        do {
            try await manager.pullChanges(into: database)
            XCTFail("Unavailable transport must fail the pull")
        } catch {
            XCTAssertEqual(error as? SyncManager.AccountError, .syncDisabled)
            XCTAssertEqual(states, [.idle, .syncing, .error(error.localizedDescription)])
            XCTAssertEqual(manager.syncState, .error(error.localizedDescription))
        }

        XCTAssertEqual(manager.lastSyncDate, previousDate)
        XCTAssertEqual(manager.syncedEntryCount, 0)
        XCTAssertEqual(try database.countEntries(), 0)
    }

    private func makeService(_ remote: PullTestRemote) -> SyncPullService {
        SyncPullService(fetch: { _ in try await remote.fetch() }, acknowledge: { try await remote.acknowledge($0) })
    }
}

private enum PullTestError: Error, Equatable {
    case fetch
    case acknowledgement
    case exhausted
}

/// The remote cursor only advances on successful acknowledgement, so a retry
/// genuinely fetches the same batch instead of supplying a new scripted result.
private actor PullTestRemote {
    struct Snapshot {
        let token: Data
        let fetchTokens: [Data]
        let acknowledgements: [Data]
    }

    private let batches: [SyncChangeBatch]
    private var index = 0
    private var token = Data([0])
    private var fetchTokens: [Data] = []
    private var acknowledgements: [Data] = []
    private var fetchFailures: Int
    private var acknowledgementFailures: Int

    init(batches: [SyncChangeBatch], fetchFailures: Int = 0, acknowledgementFailures: Int = 0) {
        self.batches = batches
        self.fetchFailures = fetchFailures
        self.acknowledgementFailures = acknowledgementFailures
    }

    func fetch() throws -> SyncChangeBatch {
        fetchTokens.append(token)
        if fetchFailures > 0 {
            fetchFailures -= 1
            throw PullTestError.fetch
        }
        guard index < batches.count else { throw PullTestError.exhausted }
        return batches[index]
    }

    func acknowledge(_ nextToken: Data) throws {
        acknowledgements.append(nextToken)
        if acknowledgementFailures > 0 {
            acknowledgementFailures -= 1
            throw PullTestError.acknowledgement
        }
        token = nextToken
        index += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(token: token, fetchTokens: fetchTokens, acknowledgements: acknowledgements)
    }
}

private actor PullTestGate {
    private var isOpen = false
    private var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(onEnter: @Sendable () -> Void) async {
        // Only hold the first request: an incorrectly accepted overlapping
        // fetch must fail the assertions, rather than deadlock the test.
        guard !hasEntered else { return }
        hasEntered = true
        onEnter()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
