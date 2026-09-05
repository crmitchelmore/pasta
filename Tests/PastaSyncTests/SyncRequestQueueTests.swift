import CloudKit
import PastaCore
import XCTest
@testable import PastaSync

@MainActor
final class SyncRequestQueueTests: XCTestCase {
    func testWithdrawalDuringPullKeepsCheckpointAndReenableRetriesSameCheckpoint() async throws {
        let database = try DatabaseManager.inMemory()
        try database.applySyncChanges(modified: [], deleted: [], checkpoint: Data([1]))
        let suspended = expectation(description: "download suspended")
        let remote = PausedRecoveryPull(suspended: suspended)
        let manager = SyncManager(pullService: SyncPullService(fetch: { try await remote.fetch($0) }))
        let queue = SyncRequestQueue()
        let recovery = SyncAccountRecovery()
        let operation: @MainActor () async -> Void = {
            await recovery.run(checkAccount: { .available }, prepare: {}, sync: {
                try await manager.pullChanges(into: database)
            })
        }
        let first = Task { await queue.run(operation) }
        await fulfillment(of: [suspended], timeout: 2)
        manager.setSyncEnabled(false)
        queue.cancelAll()
        await remote.resume()
        await first.value
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([1]))
        XCTAssertEqual(try database.countEntries(), 0)
        manager.setSyncEnabled(true)
        await queue.run(operation)
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([2]))
        XCTAssertEqual(try database.countEntries(), 1)
        let checkpoints = await remote.checkpoints
        XCTAssertEqual(checkpoints, [Data([1]), Data([1])])
    }

    func testCancelledForegroundCallerCannotDropReactivationDuringAccountLookup() async {
        let queue = SyncRequestQueue()
        let recovery = SyncAccountRecovery()
        let suspended = expectation(description: "first account lookup suspended")
        var resume: CheckedContinuation<Void, Never>?
        var lookups = 0
        var syncs = 0
        let operation: @MainActor () async -> Void = {
            await recovery.run(checkAccount: {
                lookups += 1
                if lookups == 1 {
                    await withCheckedContinuation { continuation in
                        resume = continuation
                        suspended.fulfill()
                    }
                }
                return .available
            }, prepare: {}, sync: { syncs += 1 })
        }
        let firstCaller = Task { await queue.run(operation) }
        await fulfillment(of: [suspended], timeout: 2)
        firstCaller.cancel()
        let reactivation = Task { await queue.run(operation) }
        resume?.resume()
        await firstCaller.value
        await reactivation.value
        XCTAssertEqual(lookups, 2, "Reactivation must get a fresh account check")
        XCTAssertEqual(syncs, 2, "View cancellation must not discard the queued request")
        XCTAssertEqual(recovery.availability, .available)
    }

    func testConsentWithdrawalCancelsSuspendedAttemptAndReenableStartsFresh() async {
        let queue = SyncRequestQueue()
        let recovery = SyncAccountRecovery()
        let suspended = expectation(description: "account lookup suspended before consent withdrawal")
        var resume: CheckedContinuation<Void, Never>?
        var lookups = 0
        var preparations = 0
        var syncs = 0
        let operation: @MainActor () async -> Void = {
            await recovery.run(checkAccount: {
                lookups += 1
                if lookups == 1 {
                    await withCheckedContinuation { continuation in
                        resume = continuation
                        suspended.fulfill()
                    }
                }
                return .available
            }, prepare: { preparations += 1 }, sync: { syncs += 1 })
        }
        let firstCaller = Task { await queue.run(operation) }
        await fulfillment(of: [suspended], timeout: 2)
        queue.cancelAll()
        let enabledAgain = Task { await queue.run(operation) }
        resume?.resume()
        await firstCaller.value
        await enabledAgain.value
        XCTAssertEqual(lookups, 2)
        XCTAssertEqual(preparations, 1, "Cancelled attempt cannot prepare CloudKit after re-enable")
        XCTAssertEqual(syncs, 1, "Only the new consent's attempt can transfer")
    }
}

private actor PausedRecoveryPull {
    let suspended: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var checkpoints: [Data?] = []

    init(suspended: XCTestExpectation) { self.suspended = suspended }

    func fetch(_ checkpoint: Data?) async throws -> SyncChangeBatch {
        checkpoints.append(checkpoint)
        if checkpoints.count == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                suspended.fulfill()
            }
        }
        return SyncChangeBatch(
            modified: [ClipboardEntry(content: "downloaded after consent", contentType: .text)],
            deleted: [], token: Data([2])
        )
    }

    func resume() { continuation?.resume(); continuation = nil }
}
