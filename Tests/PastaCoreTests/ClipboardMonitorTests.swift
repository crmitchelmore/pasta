import Combine
import Foundation
import XCTest
@testable import PastaCore

final class ClipboardMonitorTests: XCTestCase {
    private final class MockPasteboard: PasteboardProviding {
        var changeCount: Int = 0
        var contents: PasteboardContents?
        var metadata: PasteboardMetadata = PasteboardMetadata()
        var transient: Bool = false

        func readContents() -> PasteboardContents? { contents }
        func readMetadata() -> PasteboardMetadata { metadata }
        func isTransient() -> Bool { transient }
    }

    private struct MockWorkspace: WorkspaceProviding {
        var identifier: String?
        func frontmostApplicationIdentifier() -> String? { identifier }
    }

    func testEmitsEntryOnPasteboardChange() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("hello")

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            workspace: MockWorkspace(identifier: "com.example.App"),
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests")!),
            tickPublisher: ticks.eraseToAnyPublisher(),
            now: { Date(timeIntervalSince1970: 123) }
        )

        var received: [ClipboardEntry] = []
        let expectation = XCTestExpectation(description: "receives entry")

        let cancellable = monitor.publisher.sink { entry in
            received.append(entry)
            expectation.fulfill()
        }

        monitor.start()

        pasteboard.changeCount = 2
        pasteboard.contents = .text("hello world")
        ticks.send(())

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].contentType, .text)
        XCTAssertEqual(received[0].content, "hello world")
        XCTAssertEqual(received[0].sourceApp, "com.example.App")
        XCTAssertEqual(received[0].timestamp, Date(timeIntervalSince1970: 123))
    }

    func testStopPreventsFurtherEmissions() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("a")

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.stop")!),
            tickPublisher: ticks.eraseToAnyPublisher()
        )

        var receivedCount = 0
        let cancellable = monitor.publisher.sink { _ in receivedCount += 1 }

        monitor.start()

        pasteboard.changeCount = 2
        pasteboard.contents = .text("b")
        ticks.send(())
        XCTAssertEqual(receivedCount, 1)

        monitor.stop()

        pasteboard.changeCount = 3
        pasteboard.contents = .text("c")
        ticks.send(())
        XCTAssertEqual(receivedCount, 1)

        cancellable.cancel()
    }
    
    func testContinuitySyncDetection() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("synced text")
        pasteboard.metadata = PasteboardMetadata(isContinuitySync: true, originDeviceName: "iPhone")

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            workspace: MockWorkspace(identifier: nil),
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.continuity")!),
            tickPublisher: ticks.eraseToAnyPublisher()
        )

        var received: [ClipboardEntry] = []
        let expectation = XCTestExpectation(description: "receives continuity entry")

        let cancellable = monitor.publisher.sink { entry in
            received.append(entry)
            expectation.fulfill()
        }

        monitor.start()

        pasteboard.changeCount = 2
        ticks.send(())

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sourceApp, "Continuity")
        XCTAssertNotNil(received[0].metadata)
        XCTAssertTrue(received[0].metadata?.contains("continuitySync") == true)
    }

    func testTransientPasteboardIsIgnored() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("super-secret-password")
        pasteboard.transient = true

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            workspace: MockWorkspace(identifier: "com.example.PasswordManager"),
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.transient")!),
            tickPublisher: ticks.eraseToAnyPublisher(),
            respectTransientPasteboard: { true }
        )

        var received: [ClipboardEntry] = []
        let cancellable = monitor.publisher.sink { entry in received.append(entry) }

        monitor.start()

        pasteboard.changeCount = 2
        ticks.send(())

        // Wait briefly to ensure no async emission slips through.
        let waited = XCTestExpectation(description: "no emission")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waited.fulfill() }
        wait(for: [waited], timeout: 1.0)

        cancellable.cancel()
        XCTAssertEqual(received.count, 0, "Transient/concealed pasteboard contents must not be recorded")
    }

    func testTransientPasteboardIsCapturedWhenRespectDisabled() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("captured-anyway")
        pasteboard.transient = true

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            workspace: MockWorkspace(identifier: nil),
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.transientOptOut")!),
            tickPublisher: ticks.eraseToAnyPublisher(),
            respectTransientPasteboard: { false }
        )

        var received: [ClipboardEntry] = []
        let expectation = XCTestExpectation(description: "receives transient entry when respect disabled")
        let cancellable = monitor.publisher.sink { entry in
            received.append(entry)
            expectation.fulfill()
        }

        monitor.start()

        pasteboard.changeCount = 2
        ticks.send(())

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(received.count, 1, "Transient pasteboard must be captured when user opts out of respect")
        XCTAssertEqual(received.first?.content, "captured-anyway")
    }

    func testTransientTypeSetIncludesNSPasteboardOrgIdentifiers() {
        XCTAssertTrue(TransientPasteboardType.contains(["org.nspasteboard.TransientType"]))
        XCTAssertTrue(TransientPasteboardType.contains(["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(TransientPasteboardType.contains(["org.nspasteboard.AutoGeneratedType"]))
        XCTAssertTrue(TransientPasteboardType.contains(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(TransientPasteboardType.contains(["public.utf8-plain-text"]))
        XCTAssertFalse(TransientPasteboardType.contains([]))
    }
}
