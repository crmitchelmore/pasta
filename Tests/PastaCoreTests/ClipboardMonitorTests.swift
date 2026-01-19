import Combine
import Foundation
import XCTest
@testable import PastaCore

final class ClipboardMonitorTests: XCTestCase {
    private final class MockPasteboard: PasteboardProviding {
        var changeCount: Int = 0
        var contents: PasteboardContents?

        func readContents() -> PasteboardContents? { contents }
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
}
