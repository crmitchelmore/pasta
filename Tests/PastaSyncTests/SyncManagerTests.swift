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

        let status = try await manager.checkAccountStatus()

        XCTAssertEqual(status, CKAccountStatus.couldNotDetermine)
    }
}
