import Foundation
import PastaCore
#if canImport(UIKit)
import UIKit
#endif

/// Launch hooks honoured only when the process was started by the XCUITest
/// suite (`PastaIOSUITests`) with the `-uiTesting` launch argument.
///
/// Every hook is a no-op for normal launches: `isActive` gates all of them, so
/// an environment variable set by accident on a user's device does nothing.
/// See `PastaIOS/TESTING.md` for the full list and how the tests use them.
enum UITestConfiguration {
    /// Launch argument that enables every other hook.
    static let launchArgument = "-uiTesting"

    /// `1` wipes the local database and UserDefaults before `AppState` opens
    /// them, so every test starts from a genuinely empty install.
    static let resetStateKey = "PASTA_UI_TEST_RESET"

    /// `1` marks onboarding as completed (and the current version as seen) so
    /// tests land directly on the main tab UI.
    static let skipOnboardingKey = "PASTA_UI_TEST_SKIP_ONBOARDING"

    /// Non-empty value is written to `UIPasteboard.general` before the app
    /// captures the clipboard on activation, so the capture path is exercised
    /// deterministically regardless of what the simulator pasteboard held.
    static let pasteboardKey = "PASTA_UI_TEST_PASTEBOARD"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var shouldResetState: Bool {
        isActive && environment[resetStateKey] == "1"
    }

    static var shouldSkipOnboarding: Bool {
        isActive && environment[skipOnboardingKey] == "1"
    }

    static var pasteboardString: String? {
        guard isActive, let value = environment[pasteboardKey], !value.isEmpty else { return nil }
        return value
    }

    static var releaseVersion: String? { isActive ? environment["PASTA_UI_TEST_VERSION"] : nil }
    static var releaseBuild: String? { isActive ? environment["PASTA_UI_TEST_BUILD"] : nil }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// Applies the state-affecting hooks. Must run before the database is
    /// opened and before `hasCompletedOnboarding` is read.
    static func applyIfNeeded(databaseURL: URL, currentAppVersion: String, currentAppBuild: String) {
        guard isActive else { return }

        if shouldResetState {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            let fileManager = FileManager.default
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                try? fileManager.removeItem(at: url)
            }
        }

        if shouldSkipOnboarding {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(currentAppVersion, forKey: "pasta.ios.lastSeenVersion")
            UserDefaults.standard.set(
                ReleaseNotesPresentation.identity(version: currentAppVersion, build: currentAppBuild),
                forKey: ReleaseNotesPresentation.acknowledgedKey
            )
        }

        if let previousVersion = environment["PASTA_UI_TEST_PREVIOUS_VERSION"] {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(previousVersion, forKey: "pasta.ios.lastSeenVersion")
            UserDefaults.standard.removeObject(forKey: ReleaseNotesPresentation.acknowledgedKey)
        }

        #if canImport(UIKit)
        if let pasteboardString {
            UIPasteboard.general.string = pasteboardString
        } else if shouldResetState {
            // An empty-install test must not capture a previous test's text.
            UIPasteboard.general.items = []
        }
        #endif
    }
}
