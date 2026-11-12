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

    private final class MockWorkspace: WorkspaceProviding {
        var identifier: String?
        func frontmostApplicationIdentifier() -> String? { identifier }
    }

    /// Drives a real `ClipboardMonitor` with manual ticks and records emissions.
    private final class Harness {
        let pasteboard = MockPasteboard()
        let workspace = MockWorkspace()
        let ticks = PassthroughSubject<Void, Never>()
        let defaults: UserDefaults
        var respectTransient = true
        private(set) var received: [ClipboardEntry] = []
        private var cancellable: AnyCancellable?
        private(set) var monitor: ClipboardMonitor!

        init(suite: String) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            pasteboard.changeCount = 1
            pasteboard.contents = .text("initial")
            monitor = ClipboardMonitor(
                pasteboard: pasteboard,
                workspace: workspace,
                exclusionManager: ExclusionManager(userDefaults: defaults),
                tickPublisher: ticks.eraseToAnyPublisher(),
                now: { Date(timeIntervalSince1970: 123) },
                respectTransientPasteboard: { [unowned self] in self.respectTransient }
            )
            cancellable = monitor.publisher.sink { [unowned self] in self.received.append($0) }
            monitor.start()
        }

        /// Simulates a new copy (or, with nil, a poll that sees a changed count)
        /// and returns what the monitor emitted for it.
        @discardableResult
        func copy(_ contents: PasteboardContents?, expectEmission: Bool) -> ClipboardEntry? {
            let before = received.count
            if let contents { pasteboard.contents = contents }
            pasteboard.changeCount += 1
            ticks.send(())
            // Emission hops read queue -> main queue; pump the main run loop.
            let deadline = Date().addingTimeInterval(expectEmission ? 2 : 0.2)
            while Date() < deadline, received.count == before {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return received.count > before ? received.last : nil
        }
    }

    func testCaptureFlowReadsOffMainDedupsDiscardsStaleReadsAndStops() throws {
        let h = Harness(suite: "ClipboardMonitorTests.capture")
        h.workspace.identifier = "com.example.App"

        let text = try XCTUnwrap(h.copy(.text("hello world"), expectEmission: true))
        XCTAssertEqual(text.contentType, .text)
        XCTAssertEqual(text.content, "hello world")
        XCTAssertEqual(text.sourceApp, "com.example.App")
        XCTAssertEqual(text.timestamp, Date(timeIntervalSince1970: 123))
        // The cheap transient check stays on the polling (main) thread; the
        // potentially expensive contents read must happen off it.
        XCTAssertEqual(h.pasteboard.isTransientWasOnMainThread, true)
        XCTAssertEqual(h.pasteboard.readContentsWasOnMainThread, false)

        // Images are deduplicated by SHA-256 without retaining the bytes.
        let imageBytes = Data((0..<512_000).map { UInt8(truncatingIfNeeded: $0) })
        let image = try XCTUnwrap(h.copy(.image(imageBytes), expectEmission: true))
        XCTAssertEqual(image.contentType, .image)
        XCTAssertEqual(image.rawData, imageBytes)
        XCTAssertEqual(h.monitor.currentFingerprintForTesting, .imageHash(ClipboardEntry.sha256Hex(imageBytes)))
        XCTAssertNil(h.copy(nil, expectEmission: false), "identical image bytes must be deduplicated by hash")

        h.workspace.identifier = "com.apple.screencaptureui"
        XCTAssertEqual(h.copy(.image(Data([0x09])), expectEmission: true)?.contentType, .screenshot)
        h.workspace.identifier = "com.example.App"
        let files = try XCTUnwrap(h.copy(.filePaths(["/tmp/a", "/tmp/b"]), expectEmission: true))
        XCTAssertEqual(files.contentType, .filePath)
        XCTAssertEqual(files.content, "/tmp/a\n/tmp/b")

        // A read that races a pasteboard change is discarded; the next poll
        // captures the current contents.
        h.pasteboard.onReadContents = { [weak pasteboard = h.pasteboard] in
            pasteboard?.changeCount += 1
            pasteboard?.onReadContents = nil
        }
        XCTAssertNil(h.copy(.text("stale"), expectEmission: false))
        h.pasteboard.contents = .text("fresh")
        h.ticks.send(())
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, h.received.last?.content != "fresh" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(h.received.contains { $0.content == "stale" })
        XCTAssertEqual(h.received.last?.content, "fresh")

        h.pasteboard.metadata = PasteboardMetadata(isContinuitySync: true, originDeviceName: "iPhone")
        let continuity = try XCTUnwrap(h.copy(.text("synced text"), expectEmission: true))
        XCTAssertEqual(continuity.sourceApp, "Continuity")
        XCTAssertTrue(continuity.metadata?.contains("continuitySync") == true)
        h.pasteboard.metadata = PasteboardMetadata()

        h.monitor.stop()
        XCTAssertNil(h.copy(.text("after stop"), expectEmission: false))
    }

    func testPrivacySkipsTransientAndExcludedSources() throws {
        let transientCases: [([String], Bool)] = [
            (["org.nspasteboard.TransientType"], true),
            (["org.nspasteboard.ConcealedType"], true),
            (["org.nspasteboard.AutoGeneratedType"], true),
            (["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], true),
            (["public.utf8-plain-text"], false),
            ([], false)
        ]
        for (types, expected) in transientCases {
            XCTAssertEqual(TransientPasteboardType.contains(types), expected, "types \(types)")
        }

        let h = Harness(suite: "ClipboardMonitorTests.privacy")
        h.defaults.set("  com.apple.Terminal\n\ncom.example.Excluded  ", forKey: "pasta.excludedApps")
        let exclusions = ExclusionManager(userDefaults: h.defaults)
        XCTAssertEqual(exclusions.excludedBundleIdentifiers, ["com.apple.Terminal", "com.example.Excluded"])
        XCTAssertFalse(exclusions.isExcluded(bundleIdentifier: nil))
        XCTAssertFalse(exclusions.isExcluded(bundleIdentifier: ""))

        h.workspace.identifier = "com.example.PasswordManager"
        h.pasteboard.transient = true
        XCTAssertNil(h.copy(.text("super-secret-password"), expectEmission: false),
                     "Transient/concealed pasteboard contents must not be recorded")
        h.respectTransient = false
        XCTAssertEqual(h.copy(.text("captured-anyway"), expectEmission: true)?.content, "captured-anyway",
                       "Transient pasteboard must be captured when the user opts out of respecting it")
        h.pasteboard.transient = false

        h.workspace.identifier = "com.example.Excluded"
        XCTAssertNil(h.copy(.text("secret"), expectEmission: false))
        // Positive control: once unexcluded the same pipeline emits.
        h.defaults.set("", forKey: "pasta.excludedApps")
        XCTAssertEqual(h.copy(.text("not secret"), expectEmission: true)?.content, "not secret")
        XCTAssertEqual(h.received.map(\.content), ["captured-anyway", "not secret"])
    }
}
