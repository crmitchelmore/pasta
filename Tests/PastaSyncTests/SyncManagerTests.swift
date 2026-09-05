import CloudKit
import PastaCore
import XCTest
@testable import PastaSync

final class SyncManagerTests: XCTestCase {
    func testDisabledPushLeavesLocallyCapturedEntryPending() async throws {
        let database = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "captured while CloudKit unavailable", contentType: .text)
        try database.insert(entry)
        let manager = SyncManager(syncEnabled: false)

        do {
            // Mirror the production capture acknowledgement boundary.
            try await manager.pushEntry(entry)
            try database.markSynced(ids: [entry.id])
            XCTFail("Unavailable CloudKit must not acknowledge an upload")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .notAuthenticated)
        }

        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [entry.id])
        XCTAssertEqual(try database.syncedCount(), 0)
    }

    func testDisabledBulkPushFailsWithoutAcknowledgingPendingEntries() async throws {
        let database = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "waiting for a real upload", contentType: .text)
        try database.insert(entry)
        let manager = SyncManager(syncEnabled: false)

        do {
            _ = try await database.backfillUnsynced { entries, acknowledge in
                try await manager.pushEntries(entries, onBatchSynced: acknowledge)
            }
            XCTFail("Bulk sync must report unavailable CloudKit")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .notAuthenticated)
        }

        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [entry.id])
        XCTAssertEqual(try database.syncedCount(), 0)
    }

    func testMissingCloudKitEntitlementDisablesAccountLookup() async throws {
        let manager = SyncManager(containerIdentifier: "iCloud.com.pasta.ios")

        XCTAssertFalse(manager.cloudKitAccessAllowed)
        do {
            _ = try await manager.checkAccountStatus()
            XCTFail("An unentitled build must report the build problem, not an account outage")
        } catch SyncManager.AccountError.missingEntitlement {
            // No CloudKit container was constructed.
        }
    }

    @MainActor
    func testConsentIsRequiredForPullAndWithdrawalRetainsLocalHistory() async throws {
        let database = try DatabaseManager.inMemory()
        let pending = ClipboardEntry(content: "private offline clipboard", contentType: .text)
        try database.insert(pending)
        try database.applySyncChanges(modified: [], deleted: [], checkpoint: Data([4]))
        let manager = SyncManager(syncEnabled: false, pullService: SyncPullService(fetch: { _ in
            XCTFail("Disabled consent must not fetch remote clipboard history")
            return SyncChangeBatch(modified: [], deleted: [], token: Data([5]))
        }))
        // Also exercise a persisted enabled choice subsequently withdrawn.
        manager.setSyncEnabled(true)
        manager.setSyncEnabled(false)
        do {
            try await manager.pullChanges(into: database)
            XCTFail("Withdrawal must close the pull path even when a service exists")
        } catch SyncManager.AccountError.syncDisabled {}
        XCTAssertEqual(try database.loadSyncChangeToken(), Data([4]))
        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [pending.id])
    }

    func testDisabledAccountLookupReportsDisabledWithoutResolvingContainer() async throws {
        let manager = SyncManager(syncEnabled: false, cloudKitProvisioned: true)
        XCTAssertFalse(manager.cloudKitAccessAllowed)
        do {
            _ = try await manager.checkAccountStatus()
            XCTFail("Explicitly disabled sync must remain closed even for a provisioned host")
        } catch SyncManager.AccountError.syncDisabled {
            // An explicit privacy/transport gate always takes precedence.
        }
    }
}
