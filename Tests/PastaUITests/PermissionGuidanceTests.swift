import XCTest
import PastaCore
@testable import PastaUI

@MainActor
final class PermissionGuidanceTests: XCTestCase {
    func testIdentityPreservesAlphaDevRenamedAndLocalisedNames() {
        for name in ["Pasta Alpha", "Pasta Development", "My Clipboard", "Pâtes Alpha"] {
            let url = URL(fileURLWithPath: "/Temporary/\(name).app")
            let identity = PermissionAppIdentity(bundleURL: url, displayName: name + ".app")
            XCTAssertEqual(identity.name, name)
            XCTAssertEqual(identity.bundleURL, url)
            XCTAssertTrue(identity.isAppBundle)
        }
        XCTAssertFalse(PermissionAppIdentity(bundleURL: URL(fileURLWithPath: "/tmp/PastaApp")).isAppBundle)
    }

    func testRepeatedRequestsAlwaysOpenMatchingSettingsWithoutInventingGrant() {
        for permission in MacPermission.allCases {
            let store = MacPermissionStore(read: { .init(accessibility: false, inputMonitoring: false) })
            var opened: [URL] = []
            let model = PermissionGuidanceModel(permission: permission, store: store,
                                               identity: .init(bundleURL: URL(fileURLWithPath: "/tmp/Pasta Alpha.app")),
                                               open: { opened.append($0); return true })
            model.openSettings()
            model.openSettings()
            XCTAssertEqual(opened, [permission.settingsURL, permission.settingsURL])
            XCTAssertEqual(store.activeSessionCount, 1)
            XCTAssertFalse(store.snapshot.allows(permission))
            model.checkAgain()
            XCTAssertTrue(model.feedback.contains("still missing for Pasta Alpha"))
            model.stopChecking()
            XCTAssertEqual(store.activeSessionCount, 0)
        }
    }

    func testFailedSettingsLinkShowsManualPathAndRecheckUsesFreshState() {
        var current = MacPermissionSnapshot(accessibility: false, inputMonitoring: false)
        let store = MacPermissionStore(read: { current })
        let model = PermissionGuidanceModel(permission: .accessibility, store: store,
                                           identity: .init(bundleURL: URL(fileURLWithPath: "/tmp/Pasta Dev.app")),
                                           open: { _ in false })
        model.openSettings()
        XCTAssertFalse(model.settingsOpened)
        XCTAssertTrue(model.feedback.contains("System Settings → Privacy & Security → Accessibility"))
        current.accessibility = true
        model.checkAgain()
        XCTAssertTrue(model.feedback.contains("available for Pasta Dev"))
        XCTAssertEqual(store.activeSessionCount, 0)
        current.accessibility = false
        model.checkAgain()
        XCTAssertTrue(model.feedback.contains("still missing"))
        model.stopChecking()
    }
}
