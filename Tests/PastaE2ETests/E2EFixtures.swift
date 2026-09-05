import AppKit
import Combine
import Foundation
import SwiftUI
import XCTest

import PastaDetectors
import PastaSync
import PastaUI
@testable import PastaCore

// MARK: - Pasteboard doubles

/// Thread-safe fake `NSPasteboard`: `ClipboardMonitor` reads it on its
/// background read queue while tests mutate it from the main thread.
final class E2EPasteboard: PasteboardProviding {
    private let lock = NSLock()
    private var _changeCount = 0
    private var _contents: PasteboardContents?
    private var _metadata = PasteboardMetadata()
    private var _transient = false

    var changeCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _changeCount }
        set { lock.lock(); defer { lock.unlock() }; _changeCount = newValue }
    }

    var metadata: PasteboardMetadata {
        get { lock.lock(); defer { lock.unlock() }; return _metadata }
        set { lock.lock(); defer { lock.unlock() }; _metadata = newValue }
    }

    var transient: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _transient }
        set { lock.lock(); defer { lock.unlock() }; _transient = newValue }
    }

    /// Simulates the user copying something: bumps the change count the way
    /// AppKit does and swaps the contents.
    func copy(_ contents: PasteboardContents) {
        lock.lock()
        _contents = contents
        _changeCount += 1
        lock.unlock()
    }

    func readContents() -> PasteboardContents? {
        lock.lock(); defer { lock.unlock() }
        return _contents
    }

    func readMetadata() -> PasteboardMetadata { metadata }

    func isTransient() -> Bool { transient }
}

struct E2EWorkspace: WorkspaceProviding {
    var identifier: String?
    func frontmostApplicationIdentifier() -> String? { identifier }
}

/// Records what `PasteService` would have put on the system pasteboard.
final class E2EPasteboardWriter: PasteboardWriting {
    private(set) var writes: [PasteService.Contents] = []
    var savedContents: PasteService.SavedContents?
    private(set) var restored: [PasteService.SavedContents] = []

    var lastWrite: PasteService.Contents? { writes.last }

    func write(_ contents: PasteService.Contents) { writes.append(contents) }
    func saveCurrentContents() -> PasteService.SavedContents? { savedContents }
    func restore(_ contents: PasteService.SavedContents) { restored.append(contents) }
}

final class E2EPasteSimulator: PasteEventSimulating {
    private(set) var commandVCount = 0
    func simulateCommandV() { commandVCount += 1 }
}

// MARK: - Capture pipeline

/// The enrichment step `BackgroundService` performs between the monitor and
/// the database: classify with the detectors, attach metadata, spill image
/// bytes to `ImageStorageManager`, and materialise extracted child entries.
///
/// `BackgroundService` lives in the `PastaApp` executable target, which
/// SwiftPM tests cannot import, so this mirrors `BackgroundService.enrich`
/// and the insert loop that follows it. If that logic changes, change this.
struct E2ECapturePipeline {
    struct Result {
        var primary: ClipboardEntry
        var extracted: [ClipboardEntry]
        var envVarSplit: [ClipboardEntry]

        var allEntries: [ClipboardEntry] {
            envVarSplit.isEmpty ? [primary] + extracted : envVarSplit
        }
    }

    let database: DatabaseManager
    let imageStorage: ImageStorageManager
    let detector: ContentTypeDetector
    var configuration: DetectorConfiguration = .default
    var storeImages = true
    var extractContent = true
    var deduplicate = true

    func enrich(_ captured: ClipboardEntry) throws -> Result {
        var entry = captured

        if entry.contentType == .image || entry.contentType == .screenshot, entry.rawData != nil {
            if storeImages {
                // Production preserves inline bytes when file storage fails.
                // Use the same core operation instead of mirroring its mutation.
                try? imageStorage.persistImageData(in: &entry)
            } else {
                entry.rawData = nil
            }
            return Result(primary: entry, extracted: [], envVarSplit: [])
        }

        let output = detector.detect(in: entry.content, configuration: configuration)

        if output.primaryType == .envVarBlock, !output.splitEntries.isEmpty {
            let split = output.splitEntries.map { piece in
                ClipboardEntry(
                    content: piece.content,
                    contentType: piece.contentType,
                    timestamp: entry.timestamp,
                    sourceApp: entry.sourceApp,
                    metadata: piece.metadataJSON
                )
            }
            return Result(primary: entry, extracted: [], envVarSplit: split)
        }

        // Mirrors BackgroundService.enrich: pasteboard file URLs keep their
        // `.filePath` type regardless of what the text detectors conclude.
        if entry.contentType != .filePath {
            entry.contentType = output.primaryType
        }
        entry.metadata = output.metadataJSON

        var extracted: [ClipboardEntry] = []
        if extractContent {
            extracted = output.extractedItems.map { item in
                ClipboardEntry(
                    content: item.content,
                    contentType: item.contentType,
                    timestamp: entry.timestamp,
                    sourceApp: entry.sourceApp,
                    metadata: item.metadataJSON,
                    parentEntryId: entry.id
                )
            }
        }
        return Result(primary: entry, extracted: extracted, envVarSplit: [])
    }

    /// Enrich + persist, returning what was written.
    @discardableResult
    func ingest(_ captured: ClipboardEntry) throws -> Result {
        let result = try enrich(captured)
        for entry in result.allEntries {
            try database.insert(entry, deduplicate: deduplicate)
        }
        return result
    }
}

// MARK: - Temp environment

/// A throwaway on-disk `DatabaseManager` (real `DatabasePool`, WAL, PRAGMA
/// tuning — the same code path the app uses) plus an image directory, both
/// removed on `tearDown`.
final class E2ETempEnvironment {
    let root: URL
    let databaseURL: URL
    let imagesURL: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaE2E-\(name)-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("pasta.sqlite")
        imagesURL = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func openDatabase() throws -> DatabaseManager {
        try DatabaseManager(databaseURL: databaseURL)
    }

    func openImageStorage() throws -> ImageStorageManager {
        try ImageStorageManager(imagesDirectoryURL: imagesURL)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Monitor driving

/// Wires a `ClipboardMonitor` to a fake pasteboard with a manual tick and
/// collects what it emits.
final class E2EMonitorHarness {
    let pasteboard = E2EPasteboard()
    let ticks = PassthroughSubject<Void, Never>()
    let monitor: ClipboardMonitor
    private var cancellable: AnyCancellable?
    private(set) var emitted: [ClipboardEntry] = []

    init(sourceApp: String? = "com.example.Editor", suite: String, now: @escaping () -> Date = Date.init) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            workspace: E2EWorkspace(identifier: sourceApp),
            exclusionManager: ExclusionManager(userDefaults: defaults),
            tickPublisher: ticks.eraseToAnyPublisher(),
            now: now
        )
        cancellable = monitor.publisher.sink { [weak self] entry in
            self?.emitted.append(entry)
        }
        monitor.start()
    }

    /// Copies `contents` and polls once, waiting for the asynchronous read to
    /// publish the captured entry.
    func capture(_ contents: PasteboardContents, in testCase: XCTestCase, timeout: TimeInterval = 2.0) -> ClipboardEntry? {
        let before = emitted.count
        let expectation = XCTestExpectation(description: "monitor emits entry")
        let waiter = monitor.publisher.sink { _ in expectation.fulfill() }
        defer { waiter.cancel() }

        pasteboard.copy(contents)
        ticks.send(())
        testCase.wait(for: [expectation], timeout: timeout)
        return emitted.count > before ? emitted.last : nil
    }

    /// Copies `contents`, polls once, and gives the asynchronous read pipeline
    /// time to run; returns whatever was emitted (expected: nothing).
    func captureExpectingSilence(_ contents: PasteboardContents, in testCase: XCTestCase, settle: TimeInterval = 0.3) -> ClipboardEntry? {
        let before = emitted.count
        pasteboard.copy(contents)
        ticks.send(())

        let settled = XCTestExpectation(description: "pipeline settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { settled.fulfill() }
        testCase.wait(for: [settled], timeout: settle * 5)
        return emitted.count > before ? emitted.last : nil
    }

    func stop() {
        monitor.stop()
        cancellable?.cancel()
    }
}

/// Deterministic wall clock for the monitor: each copy is one second after
/// the previous, so re-copies (which stamp `timestamp = now`) sort newest.
final class E2EClock {
    private let lock = NSLock()
    private var current: TimeInterval

    init(start: TimeInterval = 1_700_000_000) {
        current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return Date(timeIntervalSince1970: current)
    }
}

// MARK: - Rendering

enum E2ERender {
    /// Evaluates a SwiftUI view's body off-screen the way the panel would,
    /// returning the rasterised image. A trap anywhere in the view hierarchy
    /// (bad metadata shape, force unwrap, etc.) fails the test here rather
    /// than in a user's panel.
    @MainActor
    static func snapshot<V: View>(_ view: V, size: CGSize = CGSize(width: 420, height: 640)) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.nsImage
    }
}

// MARK: - Metadata helpers

func e2eJSONDictionary(_ json: String?) -> [String: Any]? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func e2eBase64URL(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A structurally valid, unexpired JWT (jwt.io's canonical example shape).
func e2eSampleJWT() -> String {
    let header = e2eBase64URL(#"{"alg":"HS256","typ":"JWT"}"#)
    let payload = e2eBase64URL(#"{"sub":"1234567890","name":"Pasta E2E","iss":"pasta.test","iat":1516239022,"exp":4102444800}"#)
    return "\(header).\(payload).SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
}
