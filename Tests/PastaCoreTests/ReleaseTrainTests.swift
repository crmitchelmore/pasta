import XCTest
@testable import PastaCore

final class ReleaseTrainTests: XCTestCase {
    func testExistingInstallationsRemainStable() {
        XCTAssertEqual(ReleaseTrain.resolve(bundleIdentifier: "com.pasta.clipboard", metadata: nil), .stable)
        XCTAssertTrue(ReleaseTrain.stable.acceptsPeer(nil))
        XCTAssertTrue(ReleaseTrain.stable.allowsGlobalShortcut(explicitlyChosen: false))
    }
    func testAlphaIsolatesEverySharedNamespace() {
        XCTAssertEqual(ReleaseTrain.resolve(bundleIdentifier: "com.pasta.ios.alpha", metadata: nil), .alpha)
        XCTAssertNotEqual(ReleaseTrain.alpha.cloudContainer, ReleaseTrain.stable.cloudContainer)
        XCTAssertNotEqual(ReleaseTrain.alpha.tailnetPort, ReleaseTrain.stable.tailnetPort)
        XCTAssertNotEqual(ReleaseTrain.alpha.namespace("pairing"), ReleaseTrain.stable.namespace("pairing"))
        XCTAssertFalse(ReleaseTrain.alpha.acceptsPeer(nil))
        XCTAssertFalse(ReleaseTrain.alpha.acceptsPeer("stable"))
        XCTAssertFalse(ReleaseTrain.stable.acceptsPeer("alpha"))
        XCTAssertFalse(ReleaseTrain.alpha.allowsGlobalShortcut(explicitlyChosen: false))
        XCTAssertTrue(ReleaseTrain.alpha.allowsGlobalShortcut(explicitlyChosen: true))
    }
    func testArchiveConfigurationMatchesRuntimeIdentities() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/PastaCore/Resources/ReleaseTrains.json"))
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        for train in [ReleaseTrain.stable, .alpha] {
            let config = try XCTUnwrap(values[train.rawValue])
            XCTAssertEqual(config["displayName"], train.displayName)
            XCTAssertEqual(config["macBundleIdentifier"], train.macBundleIdentifier)
            XCTAssertEqual(config["iosBundleIdentifier"], train.iosBundleIdentifier)
            XCTAssertEqual(config["cloudContainer"], train.cloudContainer)
            XCTAssertEqual(config["feedURL"], train.feedURL)
        }
    }

}
