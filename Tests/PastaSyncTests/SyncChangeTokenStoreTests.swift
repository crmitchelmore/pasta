import Foundation
import XCTest
@testable import PastaSync

final class SyncChangeTokenStoreTests: XCTestCase {
    func testUpgradeIgnoresLegacyCursorThenResumesDurableCheckpoint() throws {
        let suite = "SyncChangeTokenStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1]), forKey: "com.pasta.sync.changeToken")

        XCTAssertNil(SyncChangeTokenStore.load(from: defaults),
                     "Legacy fetch success cannot skip records on the first durable pull")
        SyncChangeTokenStore.save(Data([2]), to: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(SyncChangeTokenStore.load(from: reopened), Data([2]),
                       "A later pull resumes the committed checkpoint instead of replaying forever")

        SyncChangeTokenStore.reset(in: reopened)
        XCTAssertNil(SyncChangeTokenStore.load(from: defaults),
                     "Reset requests a full pull even while the obsolete legacy token remains")
    }
}
