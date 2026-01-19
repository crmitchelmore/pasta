import XCTest
@testable import PastaCore

final class ExclusionManagerTests: XCTestCase {
    func testExcludedBundleIdentifiersParsesNewlinesAndTrims() {
        let defaults = UserDefaults(suiteName: "ExclusionManagerTests")!
        defaults.removePersistentDomain(forName: "ExclusionManagerTests")
        defaults.set("  com.apple.Terminal\n\ncom.example.App  ", forKey: "pasta.excludedApps")

        let manager = ExclusionManager(userDefaults: defaults)
        XCTAssertEqual(manager.excludedBundleIdentifiers, ["com.apple.Terminal", "com.example.App"])
    }

    func testIsExcludedHandlesNilAndEmpty() {
        let defaults = UserDefaults(suiteName: "ExclusionManagerTests.nil")!
        defaults.removePersistentDomain(forName: "ExclusionManagerTests.nil")

        let manager = ExclusionManager(userDefaults: defaults)
        XCTAssertFalse(manager.isExcluded(bundleIdentifier: nil))
        XCTAssertFalse(manager.isExcluded(bundleIdentifier: ""))
    }
}
