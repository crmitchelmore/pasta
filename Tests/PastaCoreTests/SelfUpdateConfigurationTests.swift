import Foundation
import XCTest
@testable import PastaCore

final class SelfUpdateConfigurationTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    /// Only a build with an https feed and a valid 32-byte EdDSA key can self-update;
    /// automatic checks being off does not matter.
    func testUpdateRequiresHTTPSFeedAndValidKey() {
        XCTAssertFalse(SelfUpdateConfiguration.isConfigured(info: ["SUEnableAutomaticChecks": false]))
        XCTAssertTrue(SelfUpdateConfiguration.isConfigured(info: [
            "SUFeedURL": "https://example.com/alpha/appcast.xml",
            "SUPublicEDKey": key, "SUEnableAutomaticChecks": false
        ]))
        for feed in ["", "appcast.xml", "file:///tmp/appcast.xml", "https://", "http://example.com/appcast.xml"] {
            XCTAssertFalse(SelfUpdateConfiguration.isConfigured(info: [
                "SUFeedURL": feed, "SUPublicEDKey": key
            ]), feed)
        }
        for invalidKey in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            XCTAssertFalse(SelfUpdateConfiguration.isConfigured(info: [
                "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": invalidKey
            ]), invalidKey)
        }
    }
}
