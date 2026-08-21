import Combine
import XCTest
@testable import PastaCore

final class ClipboardMonitorExclusionTests: XCTestCase {
    private final class MockPasteboard: PasteboardProviding {
        private let lock = NSLock()
        private var _changeCount = 0
        private var _contents: PasteboardContents?

        var changeCount: Int {
            get { lock.lock(); defer { lock.unlock() }; return _changeCount }
            set { lock.lock(); defer { lock.unlock() }; _changeCount = newValue }
        }

        var contents: PasteboardContents? {
            get { lock.lock(); defer { lock.unlock() }; return _contents }
            set { lock.lock(); defer { lock.unlock() }; _contents = newValue }
        }

        func readContents() -> PasteboardContents? { contents }
        func readMetadata() -> PasteboardMetadata { PasteboardMetadata() }
    }

    private struct MockWorkspace: WorkspaceProviding {
        var identifier: String?
        func frontmostApplicationIdentifier() -> String? { identifier }
    }

    func testSkipsEmissionWhenSourceAppIsExcluded() {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("initial")

        let defaults = UserDefaults(suiteName: "ClipboardMonitorExclusionTests")!
        defaults.removePersistentDomain(forName: "ClipboardMonitorExclusionTests")
        defaults.set("com.example.Excluded", forKey: "pasta.excludedApps")

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            workspace: MockWorkspace(identifier: "com.example.Excluded"),
            exclusionManager: ExclusionManager(userDefaults: defaults),
            tickPublisher: ticks.eraseToAnyPublisher(),
            now: { Date(timeIntervalSince1970: 1) }
        )

        var received: [ClipboardEntry] = []
        let cancellable = monitor.publisher.sink { received.append($0) }

        monitor.start()
        pasteboard.changeCount = 2
        pasteboard.contents = .text("secret")
        ticks.send(())

        // The read/emit pipeline is asynchronous; give it time to complete
        // before asserting nothing came through.
        let settled = XCTestExpectation(description: "pipeline settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1.0)
        XCTAssertEqual(received.count, 0)

        // Positive control: once the app is no longer excluded, the same
        // pipeline emits — proving the earlier silence was the exclusion, not
        // a stalled pipeline.
        defaults.set("", forKey: "pasta.excludedApps")
        pasteboard.changeCount = 3
        pasteboard.contents = .text("not secret")
        let emitted = XCTestExpectation(description: "receives entry once unexcluded")
        let control = monitor.publisher.sink { _ in emitted.fulfill() }
        ticks.send(())
        wait(for: [emitted], timeout: 1.0)

        cancellable.cancel()
        control.cancel()
        XCTAssertEqual(received.map(\.content), ["not secret"])
    }
}
