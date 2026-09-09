#if os(macOS)
import AppKit
import Combine

public enum MacPermission: String, CaseIterable, Sendable {
    case accessibility
    case inputMonitoring

    public var title: String { self == .accessibility ? "Accessibility" : "Input Monitoring" }
    public var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" +
            (self == .accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"))!
    }
}

/// Boolean OS checks do not distinguish a first request from a denial.
public struct MacPermissionSnapshot: Equatable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public init(accessibility: Bool, inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public func allows(_ permission: MacPermission) -> Bool {
        permission == .accessibility ? accessibility : inputMonitoring
    }

    public var allowsKeywordExpansion: Bool { accessibility && inputMonitoring }

    public static func readSystem() -> Self {
        Self(accessibility: AccessibilityPermission.isTrusted(),
             inputMonitoring: AccessibilityPermission.hasInputMonitoring())
    }
}

/// The one observable OS-backed snapshot used by permission UI and feature owners.
/// Activation checks are silent. Polling belongs only to a visible setup session.
@MainActor
public final class MacPermissionStore: ObservableObject {
    public static let shared = MacPermissionStore()
    @Published public private(set) var snapshot: MacPermissionSnapshot
    private let read: () -> MacPermissionSnapshot
    private let notifications: NotificationCenter
    private var activationObserver: NSObjectProtocol?
    private var polling: [UUID: Task<Void, Never>] = [:]
    public var activeSessionCount: Int { polling.count }

    public init(read: @escaping () -> MacPermissionSnapshot = MacPermissionSnapshot.readSystem,
                notifications: NotificationCenter = .default) {
        self.read = read
        self.notifications = notifications
        snapshot = read()
        activationObserver = notifications.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    public func refresh() {
        let current = read()
        if current != snapshot { snapshot = current }
    }

    /// A finite session, cancelled on dismissal, replacement or grant.
    @discardableResult
    public func beginSession(for permission: MacPermission, timeout: TimeInterval = 120,
                             interval: TimeInterval = 0.5) -> UUID {
        let id = UUID()
        refresh()
        guard !snapshot.allows(permission) else { return id }
        let deadline = Date().addingTimeInterval(timeout)
        polling[id] = Task { @MainActor [weak self] in
            while !Task.isCancelled && Date() < deadline {
                do { try await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000)) }
                catch { break }
                guard !Task.isCancelled, let self else { break }
                self.refresh()
                if self.snapshot.allows(permission) { break }
            }
            self?.polling.removeValue(forKey: id)
        }
        return id
    }

    public func endSession(_ id: UUID) { polling.removeValue(forKey: id)?.cancel() }

    deinit {
        if let activationObserver { notifications.removeObserver(activationObserver) }
        for task in polling.values { task.cancel() }
    }
}

/// Owns a protected event monitor. Failed registration can be retried on activation.
@MainActor
public final class PermissionDependentMonitor {
    private var monitor: Any?
    private let start: () -> Any?
    private let stop: (Any) -> Void
    public var isRunning: Bool { monitor != nil }

    public init(start: @escaping () -> Any?, stop: @escaping (Any) -> Void) {
        self.start = start
        self.stop = stop
    }

    public func update(enabled: Bool, snapshot: MacPermissionSnapshot, restart: Bool = false) {
        // Access may have been revoked and granted while the app was inactive.
        // The final OS snapshot can match even though the old monitor is unusable.
        if restart { stopMonitoring() }
        if enabled && snapshot.allowsKeywordExpansion {
            if monitor == nil { monitor = start() }
        } else {
            stopMonitoring()
        }
    }

    public func stopMonitoring() {
        if let monitor { stop(monitor); self.monitor = nil }
    }

    deinit { if let monitor { stop(monitor) } }
}
#endif
