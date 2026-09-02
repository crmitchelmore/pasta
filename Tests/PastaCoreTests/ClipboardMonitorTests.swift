import Combine
import Foundation
import XCTest
@testable import PastaCore

final class ClipboardMonitorTests: XCTestCase {
    /// Thread-safe mock: the monitor reads contents on a background queue while
    /// tests mutate state from the test thread.
    private final class MockPasteboard: PasteboardProviding {
        private let lock = NSLock()
        private var _changeCount = 0
        private var _contents: PasteboardContents?
        private var _metadata = PasteboardMetadata()
        private var _transient = false
        private var _onReadContents: (() -> Void)?
        private var _readContentsWasOnMainThread: Bool?
        private var _isTransientWasOnMainThread: Bool?

        var changeCount: Int {
            get { lock.lock(); defer { lock.unlock() }; return _changeCount }
            set { lock.lock(); defer { lock.unlock() }; _changeCount = newValue }
        }

        var contents: PasteboardContents? {
            get { lock.lock(); defer { lock.unlock() }; return _contents }
            set { lock.lock(); defer { lock.unlock() }; _contents = newValue }
        }

        var metadata: PasteboardMetadata {
            get { lock.lock(); defer { lock.unlock() }; return _metadata }
            set { lock.lock(); defer { lock.unlock() }; _metadata = newValue }
        }

        var transient: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _transient }
            set { lock.lock(); defer { lock.unlock() }; _transient = newValue }
        }

        /// Runs inside `readContents()` before returning, so tests can simulate
        /// the pasteboard changing while a read is in flight.
        var onReadContents: (() -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _onReadContents }
            set { lock.lock(); defer { lock.unlock() }; _onReadContents = newValue }
        }

        var readContentsWasOnMainThread: Bool? {
            lock.lock(); defer { lock.unlock() }; return _readContentsWasOnMainThread
        }

        var isTransientWasOnMainThread: Bool? {
            lock.lock(); defer { lock.unlock() }; return _isTransientWasOnMainThread
        }

        func readContents() -> PasteboardContents? {
            lock.lock()
            _readContentsWasOnMainThread = Thread.isMainThread
            let hook = _onReadContents
            let value = _contents
            lock.unlock()
            hook?()
            return value
        }

        func readMetadata() -> PasteboardMetadata { metadata }

        func isTransient() -> Bool {
            lock.lock(); defer { lock.unlock() }
            _isTransientWasOnMainThread = Thread.isMainThread
            return _transient
        }
    }

    private struct MockWorkspace: WorkspaceProviding {
        var identifier: String?
        func frontmostApplicationIdentifier() -> String? { identifier }
    }

    /// Pumps the main runloop long enough for any in-flight async read/emit to
    /// have completed, without asserting that anything was emitted.
    private func settle(_ delay: TimeInterval = 0.2) {
        let waited = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { waited.fulfill() }
        wait(for: [waited], timeout: max(1.0, delay * 5))
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

    func testReadsContentsOffThePollingThread() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("a")

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.offMain")!),
            tickPublisher: ticks.eraseToAnyPublisher()
        )

        let expectation = XCTestExpectation(description: "receives entry")
        let cancellable = monitor.publisher.sink { _ in expectation.fulfill() }

        monitor.start()

        pasteboard.changeCount = 2
        pasteboard.contents = .text("b")
        XCTAssertTrue(Thread.isMainThread, "test setup expects ticks sent from the main thread")
        ticks.send(())

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        // The cheap transient check stays on the polling (main) thread; the
        // potentially expensive contents read must happen off it.
        XCTAssertEqual(pasteboard.isTransientWasOnMainThread, true)
        XCTAssertEqual(pasteboard.readContentsWasOnMainThread, false)
    }

    func testDuplicateImageDedupedByHashWithoutRetainingBytes() throws {
        let imageBytes = Data((0..<512_000).map { UInt8(truncatingIfNeeded: $0) })

        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .image(imageBytes)

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.imageDedup")!),
            tickPublisher: ticks.eraseToAnyPublisher()
        )

        var received: [ClipboardEntry] = []
        let expectation = XCTestExpectation(description: "receives image entry")
        let cancellable = monitor.publisher.sink { entry in
            received.append(entry)
            expectation.fulfill()
        }

        monitor.start()

        pasteboard.changeCount = 2
        ticks.send(())
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].contentType, .image)
        XCTAssertEqual(received[0].rawData, imageBytes)

        // Dedup state holds a SHA-256, not the image bytes.
        XCTAssertEqual(
            monitor.currentFingerprintForTesting,
            .imageHash(ClipboardEntry.sha256Hex(imageBytes))
        )

        // Re-copying identical bytes (new changeCount) must not re-emit.
        pasteboard.changeCount = 3
        ticks.send(())
        settle()

        cancellable.cancel()
        XCTAssertEqual(received.count, 1, "identical image bytes must be deduplicated by hash")
    }

    func testStaleReadDiscardedWhenPasteboardChangesDuringRead() throws {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("original")

        let ticks = PassthroughSubject<Void, Never>()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            exclusionManager: ExclusionManager(userDefaults: UserDefaults(suiteName: "ClipboardMonitorTests.staleRead")!),
            tickPublisher: ticks.eraseToAnyPublisher()
        )

        var received: [ClipboardEntry] = []
        let cancellable = monitor.publisher.sink { entry in received.append(entry) }

        monitor.start()

        // Simulate the pasteboard changing mid-read: the read returns "stale"
        // but by the time it finishes the changeCount has moved on.
        pasteboard.changeCount = 2
        pasteboard.contents = .text("stale")
        pasteboard.onReadContents = { [weak pasteboard] in
            pasteboard?.changeCount = 3
            pasteboard?.onReadContents = nil
        }
        ticks.send(())
        settle()
        XCTAssertEqual(received.count, 0, "a read that raced a pasteboard change must be discarded")

        // The next poll sees the new changeCount and captures the new contents.
        pasteboard.contents = .text("fresh")
        let expectation = XCTestExpectation(description: "receives fresh entry")
        let freshCancellable = monitor.publisher.sink { _ in expectation.fulfill() }
        ticks.send(())
        wait(for: [expectation], timeout: 1.0)

        cancellable.cancel()
        freshCancellable.cancel()
        XCTAssertEqual(received.map(\.content), ["fresh"])
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
        let firstEmission = XCTestExpectation(description: "receives first entry")
        let cancellable = monitor.publisher.sink { _ in
            receivedCount += 1
            firstEmission.fulfill()
        }

        monitor.start()

        pasteboard.changeCount = 2
        pasteboard.contents = .text("b")
        ticks.send(())
        wait(for: [firstEmission], timeout: 1.0)
        XCTAssertEqual(receivedCount, 1)

        monitor.stop()

        pasteboard.changeCount = 3
        pasteboard.contents = .text("c")
        ticks.send(())
        settle()
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
        settle()

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

    func testSkipsEmissionWhenSourceAppIsExcluded() {
        let pasteboard = MockPasteboard()
        pasteboard.changeCount = 1
        pasteboard.contents = .text("initial")

        let defaults = UserDefaults(suiteName: "ClipboardMonitorTests.exclusion")!
        defaults.removePersistentDomain(forName: "ClipboardMonitorTests.exclusion")
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
        settle()
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

    func testTransientTypeSetIncludesNSPasteboardOrgIdentifiers() {
        XCTAssertTrue(TransientPasteboardType.contains(["org.nspasteboard.TransientType"]))
        XCTAssertTrue(TransientPasteboardType.contains(["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(TransientPasteboardType.contains(["org.nspasteboard.AutoGeneratedType"]))
        XCTAssertTrue(TransientPasteboardType.contains(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(TransientPasteboardType.contains(["public.utf8-plain-text"]))
        XCTAssertFalse(TransientPasteboardType.contains([]))
    }
}
