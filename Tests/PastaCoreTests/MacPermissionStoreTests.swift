#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import PastaCore

@MainActor
final class MacPermissionStoreTests: XCTestCase {
    /// Keyword expansion needs both Accessibility and Input Monitoring: every
    /// screen must see grants/revocations, polling must stop on grant, dismissal
    /// or timeout, and the dependent event monitor must follow the snapshot.
    func testPermissionStoreAndDependentMonitorFollowGrantsAndRevocations() async throws {
        var current = MacPermissionSnapshot(accessibility: false, inputMonitoring: false)
        var reads = 0
        let notifications = NotificationCenter()
        let store = MacPermissionStore(read: { reads += 1; return current }, notifications: notifications)
        var onboarding: [MacPermissionSnapshot] = []
        var settings: [MacPermissionSnapshot] = []
        let a = store.$snapshot.sink { onboarding.append($0) }
        let b = store.$snapshot.sink { settings.append($0) }
        current = .init(accessibility: true, inputMonitoring: true)
        store.refresh()
        current.accessibility = false
        store.refresh()
        store.refresh()
        XCTAssertEqual(onboarding, settings)
        XCTAssertEqual(onboarding.count, 3)
        XCTAssertFalse(store.snapshot.allowsKeywordExpansion)
        withExtendedLifetime((a, b)) {}

        // App activation refreshes even when no polling session is running.
        current = .init(accessibility: true, inputMonitoring: true)
        store.refresh()
        current.inputMonitoring = false
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 where store.snapshot.inputMonitoring { await Task.yield() }
        XCTAssertFalse(store.snapshot.inputMonitoring)
        XCTAssertEqual(store.activeSessionCount, 0)

        current = .init(accessibility: false, inputMonitoring: false)
        let dismissed = store.beginSession(for: .accessibility, interval: 0.002)
        store.endSession(dismissed)
        let afterDismissal = reads
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(reads, afterDismissal)
        store.beginSession(for: .accessibility, timeout: 0.02, interval: 0.002)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.activeSessionCount, 0)
        store.beginSession(for: .inputMonitoring, interval: 0.002)
        current.inputMonitoring = true
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(store.snapshot.inputMonitoring)
        XCTAssertEqual(store.activeSessionCount, 0)

        // A polling session must not keep its store alive.
        var transient: MacPermissionStore? = MacPermissionStore(
            read: { .init(accessibility: false, inputMonitoring: false) }, notifications: NotificationCenter())
        weak var weakStore = transient
        transient?.beginSession(for: .accessibility, interval: 0.002)
        await Task.yield()
        transient = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(weakStore)

        var starts = 0
        var stops = 0
        let monitor = PermissionDependentMonitor(start: { starts += 1; return starts }, stop: { _ in stops += 1 })
        let granted = MacPermissionSnapshot(accessibility: true, inputMonitoring: true)
        monitor.update(enabled: false, snapshot: granted)
        XCTAssertEqual(starts, 0)
        monitor.update(enabled: true, snapshot: granted)
        monitor.update(enabled: true, snapshot: granted)
        XCTAssertEqual(starts, 1)
        for denied in [MacPermissionSnapshot(accessibility: false, inputMonitoring: true),
                       MacPermissionSnapshot(accessibility: true, inputMonitoring: false)] {
            monitor.update(enabled: true, snapshot: denied)
            XCTAssertFalse(monitor.isRunning)
            monitor.update(enabled: true, snapshot: granted)
            XCTAssertTrue(monitor.isRunning)
        }
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(stops, 2)
        // Activation re-arms even when the final snapshot is unchanged.
        monitor.update(enabled: true, snapshot: granted, restart: true)
        XCTAssertEqual(starts, 4)
        XCTAssertEqual(stops, 3)
        XCTAssertTrue(monitor.isRunning)
        monitor.update(enabled: false, snapshot: granted)
        XCTAssertEqual(stops, 4)

        // A failed registration can be retried, and teardown removes the monitor.
        var attempts = 0
        var retryStops = 0
        var retrying: PermissionDependentMonitor? = PermissionDependentMonitor(start: {
            attempts += 1
            return attempts == 1 ? nil : attempts
        }, stop: { _ in retryStops += 1 })
        retrying?.update(enabled: true, snapshot: granted)
        XCTAssertFalse(retrying!.isRunning)
        retrying?.update(enabled: true, snapshot: granted)
        XCTAssertTrue(retrying!.isRunning)
        retrying = nil
        XCTAssertEqual(retryStops, 1)
    }
}
#endif
