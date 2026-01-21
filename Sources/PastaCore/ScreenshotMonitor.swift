import Combine
import Foundation
import os.log

#if canImport(CoreServices)
import CoreServices
#endif

/// Thread-safe wrapper for seen paths set with size limit
private final class SeenPathsStore {
    private var paths: Set<String> = []
    private var pathsOrder: [String] = []  // Track insertion order for LRU eviction
    private let lock = NSLock()
    private let maxSize = 10_000  // Limit to prevent unbounded growth
    
    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(path)
    }
    
    func insert(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !paths.contains(path) else { return }
        
        // Evict oldest entries if at capacity
        while paths.count >= maxSize && !pathsOrder.isEmpty {
            let oldest = pathsOrder.removeFirst()
            paths.remove(oldest)
        }
        
        paths.insert(path)
        pathsOrder.append(path)
    }
    
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        paths.removeAll()
        pathsOrder.removeAll()
    }
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }
}

public final class ScreenshotMonitor {
    public var publisher: AnyPublisher<ClipboardEntry, Never> {
        subject.eraseToAnyPublisher()
    }

    private let fileManager: FileManager
    private let now: () -> Date

    private let subject = PassthroughSubject<ClipboardEntry, Never>()
    
    private var currentDirectoryURL: URL?
    private let seenPaths = SeenPathsStore()
    private var captureStartTime: Date = Date()
    
    // FSEvents stream for efficient file monitoring
    private var eventStream: FSEventStreamRef?
    private var isRunning = false
    
    // Fallback polling
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval

    private static let allowedExtensions: Set<String> = ["png", "heic", "jpg", "jpeg", "tiff", "tif"]
    
    // Screenshot filename patterns (localized variants)
    private static let screenshotPrefixes: [String] = [
        "screenshot",      // macOS Sequoia+ (English)
        "screen shot",     // Older macOS (English)
        "bildschirmfoto",  // German
        "capture d'écran", // French
        "captura de pantalla", // Spanish
        "スクリーンショット",   // Japanese
        "截屏",             // Chinese (Simplified)
        "截圖",             // Chinese (Traditional)
    ]

    public init(
        fileManager: FileManager = .default,
        pollInterval: TimeInterval = 1.0,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        self.pollInterval = pollInterval
    }
    
    deinit {
        stop()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        captureStartTime = now().addingTimeInterval(-1)
        
        guard let directoryURL = resolveDirectoryURL() else {
            PastaLogger.clipboard.warning("Screenshot directory not available, monitoring disabled")
            return
        }
        
        currentDirectoryURL = directoryURL
        
        // Seed seen paths with existing files to avoid capturing old screenshots
        seedSeenPaths(in: directoryURL)
        
        // Try to use FSEvents for efficient monitoring
        if startFSEventsStream(for: directoryURL) {
            PastaLogger.clipboard.info("Started FSEvents monitoring for screenshots at \(directoryURL.path)")
        } else {
            // Fallback to polling
            startPolling()
            PastaLogger.clipboard.info("Started polling for screenshots at \(directoryURL.path)")
        }
    }

    public func stop() {
        isRunning = false
        stopFSEventsStream()
        stopPolling()
    }
    
    // MARK: - FSEvents
    
    private func startFSEventsStream(for directoryURL: URL) -> Bool {
        #if canImport(CoreServices)
        let pathsToWatch = [directoryURL.path] as CFArray
        
        // Use passRetained to prevent use-after-free - we release in stopFSEventsStream
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, _, _) in
                guard let info = info else { return }
                // Use takeUnretainedValue since we manage the retain manually
                let monitor = Unmanaged<ScreenshotMonitor>.fromOpaque(info).takeUnretainedValue()
                
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                for path in paths {
                    monitor.handleFSEvent(path: path)
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 500ms latency
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            // Release the retain we added since stream creation failed
            Unmanaged.passUnretained(self).release()
            return false
        }
        
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        
        if FSEventStreamStart(stream) {
            eventStream = stream
            return true
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // Release the retain we added since stream failed to start
            Unmanaged.passUnretained(self).release()
            return false
        }
        #else
        return false
        #endif
    }
    
    private func stopFSEventsStream() {
        #if canImport(CoreServices)
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            // Release the retain we added in startFSEventsStream
            Unmanaged.passUnretained(self).release()
        }
        #endif
    }
    
    private func handleFSEvent(path: String) {
        let url = URL(fileURLWithPath: path)
        processFile(at: url)
    }
    
    // MARK: - Polling fallback
    
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
    }
    
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollOnce() {
        guard let directoryURL = resolveDirectoryURL() else { return }

        if currentDirectoryURL?.path != directoryURL.path {
            currentDirectoryURL = directoryURL
            seenPaths.removeAll()
            captureStartTime = now().addingTimeInterval(-1)
            seedSeenPaths(in: directoryURL)
            PastaLogger.clipboard.info("Screenshot directory changed to \(directoryURL.path)")
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to list screenshot directory")
            return
        }

        for url in urls {
            processFile(at: url)
        }
    }
    
    // MARK: - File Processing
    
    private func seedSeenPaths(in directoryURL: URL) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        
        for url in urls {
            seenPaths.insert(url.path)
        }
        PastaLogger.clipboard.debug("Seeded \(seenPaths.count) existing files in screenshot directory")
    }
    
    private func processFile(at url: URL) {
        let path = url.path
        if seenPaths.contains(path) { return }
        
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        guard let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true else {
            seenPaths.insert(path)
            return
        }

        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            seenPaths.insert(path)
            return
        }

        guard isScreenshotFile(url) else {
            seenPaths.insert(path)
            return
        }

        if let creationDate = values.creationDate, creationDate < captureStartTime {
            seenPaths.insert(path)
            return
        }

        // Wait for file to be fully written (size > 0)
        if let size = values.fileSize, size == 0 {
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to read screenshot file at \(path)")
            return
        }

        let timestamp = values.creationDate ?? values.contentModificationDate ?? now()
        let entry = ClipboardEntry(
            content: url.lastPathComponent,
            contentType: .screenshot,
            rawData: data,
            timestamp: timestamp
        )

        PastaLogger.clipboard.info("Captured screenshot: \(url.lastPathComponent)")
        subject.send(entry)
        seenPaths.insert(path)
    }

    private func resolveDirectoryURL() -> URL? {
        if let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture"),
           let location = domain["location"] as? String {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased() == "clipboard" { return nil }

            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }

            PastaLogger.clipboard.warning("Screenshot directory not accessible at \(expanded)")
            return nil
        }

        return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private func isScreenshotFile(_ url: URL) -> Bool {
        // First check metadata flag (most reliable when available)
        if let meta = screenshotMetadataFlag(for: url) {
            return meta
        }

        // Fall back to filename pattern matching
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        
        for prefix in Self.screenshotPrefixes {
            if name.hasPrefix(prefix) {
                return true
            }
        }
        
        // Also check if the name contains "screen" followed by common patterns
        if name.contains("screen shot") || name.contains("screenshot") {
            return true
        }
        
        return false
    }

    private func screenshotMetadataFlag(for url: URL) -> Bool? {
#if canImport(CoreServices)
        let key = "kMDItemIsScreenCapture" as CFString
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, key) as? Bool
#else
        return nil
#endif
    }
}
