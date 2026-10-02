#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import PastaCore

@MainActor
final class MacPermissionStoreTests: XCTestCase {
    func testAllSubscribersReceiveGrantAndRevocation() {
        var current = MacPermissionSnapshot(accessibility: false, inputMonitoring: false)
        let store = MacPermissionStore(read: { current }, notifications: NotificationCenter())
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
    }

    func testActivationRefreshesAfterPollingHasEnded() async throws {
        var current = MacPermissionSnapshot(accessibility: true, inputMonitoring: true)
        let notifications = NotificationCenter()
        let store = MacPermissionStore(read: { current }, notifications: notifications)
        current.inputMonitoring = false
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 where store.snapshot.inputMonitoring { await Task.yield() }
        XCTAssertFalse(store.snapshot.inputMonitoring)
        XCTAssertEqual(store.activeSessionCount, 0)
    }

    func testPollingStopsOnGrantDismissalAndTimeout() async throws {
        var current = MacPermissionSnapshot(accessibility: false, inputMonitoring: false)
        var reads = 0
        let store = MacPermissionStore(read: { reads += 1; return current }, notifications: NotificationCenter())
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
    }

    func testPollingDoesNotKeepStoreAlive() async throws {
        var store: MacPermissionStore? = MacPermissionStore(
            read: { .init(accessibility: false, inputMonitoring: false) }, notifications: NotificationCenter())
        weak var weakStore = store
        store?.beginSession(for: .accessibility, interval: 0.002)
        await Task.yield()
        store = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(weakStore)
    }

    func testMonitorStartsOnceStopsOnEitherRevocationAndRearms() {
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
        monitor.update(enabled: false, snapshot: granted)
        XCTAssertEqual(stops, 3)
    }

    func testFailedMonitorRegistrationCanRetryAndTeardownRemovesMonitor() {
        var attempts = 0
        var stops = 0
        var monitor: PermissionDependentMonitor? = PermissionDependentMonitor(start: {
            attempts += 1
            return attempts == 1 ? nil : attempts
        }, stop: { _ in stops += 1 })
        let granted = MacPermissionSnapshot(accessibility: true, inputMonitoring: true)
        monitor?.update(enabled: true, snapshot: granted)
        XCTAssertFalse(monitor!.isRunning)
        monitor?.update(enabled: true, snapshot: granted)
        XCTAssertTrue(monitor!.isRunning)
        monitor = nil
        XCTAssertEqual(stops, 1)
    }

    func testActivationRearmsMonitorEvenWhenFinalSnapshotIsUnchanged() {
        var starts = 0
        var stops = 0
        let monitor = PermissionDependentMonitor(start: { starts += 1; return starts }, stop: { _ in stops += 1 })
        let granted = MacPermissionSnapshot(accessibility: true, inputMonitoring: true)
        monitor.update(enabled: true, snapshot: granted)
        monitor.update(enabled: true, snapshot: granted, restart: true)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(monitor.isRunning)
    }
}
#endif
