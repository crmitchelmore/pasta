import AppKit
import PastaCore

public struct PermissionAppIdentity: Equatable {
    public let bundleURL: URL
    public let name: String
    var isAppBundle: Bool { bundleURL.pathExtension.lowercased() == "app" }

    public static var current: Self { Self(bundleURL: Bundle.main.bundleURL) }

    public init(bundleURL: URL, displayName: String? = nil) {
        self.bundleURL = bundleURL
        let displayed = displayName ?? FileManager.default.displayName(atPath: bundleURL.path)
        name = displayed.hasSuffix(".app") ? String(displayed.dropLast(4)) : displayed
    }
}

/// Testable recovery actions; opening Settings is never evidence of a grant.
@MainActor
final class PermissionGuidanceModel: ObservableObject {
    let store: MacPermissionStore
    let identity: PermissionAppIdentity
    let permission: MacPermission
    @Published private(set) var feedback = ""
    @Published private(set) var settingsOpened = true
    private let openSettingsURL: (URL) -> Bool
    private var session: UUID?

    init(permission: MacPermission, store: MacPermissionStore,
         identity: PermissionAppIdentity, open: @escaping (URL) -> Bool) {
        self.permission = permission
        self.store = store
        self.identity = identity
        self.openSettingsURL = open
    }

    func openSettings() {
        beginChecking()
        settingsOpened = openSettingsURL(permission.settingsURL)
        if !settingsOpened {
            feedback = "Open System Settings → Privacy & Security → \(permission.title)."
        }
    }

    func checkAgain() {
        store.refresh()
        feedback = store.snapshot.allows(permission)
            ? "\(permission.title) access is available for \(identity.name)."
            : "\(permission.title) access is still missing for \(identity.name). Check its switch in System Settings."
        beginChecking()
    }

    func beginChecking() {
        stopChecking()
        session = store.beginSession(for: permission)
    }

    func stopChecking() {
        if let session { store.endSession(session) }
        session = nil
    }
}
