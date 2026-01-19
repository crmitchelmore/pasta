import Combine
import XCTest
@testable import PastaCore

final class ClipboardMonitorExclusionTests: XCTestCase {
    private final class MockPasteboard: PasteboardProviding {
        var changeCount: Int = 0
        var contents: PasteboardContents?
        func readContents() -> PasteboardContents? { contents }
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

        var receivedCount = 0
        let cancellable = monitor.publisher.sink { _ in receivedCount += 1 }

        monitor.start()
        pasteboard.changeCount = 2
        pasteboard.contents = .text("secret")
        ticks.send(())

        XCTAssertEqual(receivedCount, 0)
        cancellable.cancel()
    }
}
