import CloudKit
import XCTest
@testable import PastaSync

final class SyncManagerTests: XCTestCase {
    func testMissingCloudKitEntitlementDisablesAccountLookup() async throws {
        let manager = SyncManager(containerIdentifier: "iCloud.com.pasta.ios")

        let status = try await manager.checkAccountStatus()

        XCTAssertEqual(status, CKAccountStatus.couldNotDetermine)
    }
}
