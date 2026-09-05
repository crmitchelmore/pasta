import CloudKit
import PastaCore
import XCTest
@testable import PastaSync

@MainActor
final class SyncAccountRecoveryTests: XCTestCase {
    func testOfflineLaunchThenRetryAppliesHistoryAndRetainsPendingUploads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.sqlite")
        let database = try DatabaseManager(databaseURL: url)
        let pending = ClipboardEntry(content: "local offline capture", contentType: .text)
        let remote = ClipboardEntry(content: "history from Mac", contentType: .text)
        try database.insert(pending)
        let pull = SyncPullService(fetch: { token in
            XCTAssertNil(token)
            return SyncChangeBatch(modified: [remote], deleted: [], token: Data([7]))
        })
        let recovery = SyncAccountRecovery()
        var checks = 0
        var prepared = 0
        var syncs = 0
        let check: () async throws -> CKAccountStatus = {
            checks += 1
            return checks == 1 ? .temporarilyUnavailable : .available
        }
        let sync: () async throws -> Void = {
            syncs += 1
            try await pull.pull(into: database)
        }

        await recovery.run(checkAccount: check, prepare: { prepared += 1 }, sync: sync)
        XCTAssertEqual(recovery.availability, .temporarilyUnavailable)
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(syncs, 0)
        XCTAssertNil(try database.loadSyncChangeToken())
        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [pending.id])

        // Same coordinator instance, as on foreground/Sync Now. No reset,
        // relaunch or cache deletion is needed to recover an unavailable start.
        await recovery.run(checkAccount: check, prepare: { prepared += 1 }, sync: sync)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(syncs, 1)
        XCTAssertEqual(recovery.availability, .available)
        XCTAssertNil(recovery.errorMessage)
        let reopened = try DatabaseManager(databaseURL: url)
        XCTAssertEqual(try reopened.loadSyncChangeToken(), Data([7]))
        XCTAssertEqual(try reopened.fetch(id: remote.id)?.content, remote.content)
        XCTAssertEqual(try reopened.fetchUnsynced().map(\.id), [pending.id], "Account recovery must not acknowledge an upload that never happened")
    }

    func testUnavailableAccountsNeverPrepareOrTransferAndExplainRecovery() async {
        let cases: [(CKAccountStatus, SyncAccountRecovery.Availability)] = [
            (.noAccount, .noAccount), (.restricted, .restricted),
            (.temporarilyUnavailable, .temporarilyUnavailable), (.couldNotDetermine, .couldNotDetermine)
        ]
        let recovery = SyncAccountRecovery()
        for (account, expected) in cases {
            await recovery.run(checkAccount: { account }, prepare: {
                XCTFail("Account unavailable: no zone/subscription mutation")
            }, sync: { XCTFail("Account unavailable: no clipboard transfer") })
            XCTAssertEqual(recovery.availability, expected)
            XCTAssertNotNil(recovery.availability.guidance)
        }
    }

    func testSignOutAndAccountLookupErrorReplacePreviousConnectedStatus() async {
        let recovery = SyncAccountRecovery()
        await recovery.run(checkAccount: { .available }, prepare: {}, sync: {})
        XCTAssertEqual(recovery.availability, .available)
        await recovery.run(checkAccount: { .noAccount }, prepare: {
            XCTFail("Signed-out account cannot prepare sync")
        }, sync: { XCTFail("Signed-out account cannot transfer clipboard") })
        XCTAssertEqual(recovery.availability, .noAccount)
        await recovery.run(checkAccount: { throw CKError(.networkUnavailable) }, prepare: {}, sync: {})
        XCTAssertEqual(recovery.availability, .couldNotDetermine)
        XCTAssertNotNil(recovery.errorMessage)
        await recovery.run(checkAccount: { .available }, prepare: {}, sync: {})
        XCTAssertEqual(recovery.availability, .available)
        XCTAssertNil(recovery.errorMessage)
    }

    func testFailedPreparationRetriesBeforeAnyTransfer() async {
        let recovery = SyncAccountRecovery()
        var attempts = 0
        var transfers = 0
        let prepare: () async throws -> Void = {
            attempts += 1
            if attempts == 1 { throw CKError(.networkFailure) }
        }
        await recovery.run(checkAccount: { .available }, prepare: prepare, sync: { transfers += 1 })
        XCTAssertEqual(transfers, 0)
        XCTAssertNotNil(recovery.errorMessage)
        await recovery.run(checkAccount: { .available }, prepare: prepare, sync: { transfers += 1 })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(transfers, 1)
        XCTAssertNil(recovery.errorMessage)
    }

    func testFailedPullPreservesDurableCheckpointThenRetryAdvancesIt() async throws {
        let database = try DatabaseManager.inMemory()
        let remote = ClipboardEntry(content: "download after network recovery", contentType: .text)
        try database.applySyncChanges(modified: [], deleted: [], checkpoint: Data([1]))
        let failingPull = SyncPullService(fetch: { token in
            XCTAssertEqual(token, Data([1]))
            throw CKError(.networkFailure)
        })
        let recovery = SyncAccountRecovery()
        await recovery.run(checkAccount: { .available }, prepare: {}, sync: {
            try await failingPull.pull(into: database)
        })
        XCTAssertNotNil(recovery.errorMessage)
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([1]))
        XCTAssertNil(try database.fetch(id: remote.id))
        let retryPull = SyncPullService(fetch: { token in
            XCTAssertEqual(token, Data([1]))
            return SyncChangeBatch(modified: [remote], deleted: [], token: Data([2]))
        })
        await recovery.run(checkAccount: { .available }, prepare: {}, sync: {
            try await retryPull.pull(into: database)
        })
        XCTAssertNil(recovery.errorMessage)
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([2]))
        XCTAssertNotNil(try database.fetch(id: remote.id))
    }

    func testUnprovisionedBuildIsDistinctFromAccountOutage() async {
        let recovery = SyncAccountRecovery()
        await recovery.run(checkAccount: { throw SyncManager.AccountError.missingEntitlement }, prepare: {
            XCTFail("Unprovisioned builds must not prepare CloudKit")
        }, sync: { XCTFail("Unprovisioned builds must not transfer data") })
        XCTAssertEqual(recovery.availability, .unavailableBuild)
        XCTAssertNotNil(recovery.errorMessage)
    }
}
