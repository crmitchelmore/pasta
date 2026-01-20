import Combine
import Foundation
import os.log

#if canImport(CoreServices)
import CoreServices
#endif

public final class ScreenshotMonitor {
    public var publisher: AnyPublisher<ClipboardEntry, Never> {
        subject.eraseToAnyPublisher()
    }

    private let fileManager: FileManager
    private let tickPublisher: AnyPublisher<Void, Never>
    private let now: () -> Date

    private let subject = PassthroughSubject<ClipboardEntry, Never>()
    private var cancellable: AnyCancellable?

    private var currentDirectoryURL: URL?
    private var seenPaths: Set<String> = []
    private var captureStartTime: Date = Date()

    private static let allowedExtensions: Set<String> = ["png", "heic", "jpg", "jpeg", "tiff", "tif"]

    public init(
        fileManager: FileManager = .default,
        pollInterval: TimeInterval = 1.0,
        tickPublisher: AnyPublisher<Void, Never>? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now

        if let tickPublisher {
            self.tickPublisher = tickPublisher
        } else {
            self.tickPublisher = Timer
                .publish(every: pollInterval, on: .main, in: .common)
                .autoconnect()
                .map { _ in () }
                .eraseToAnyPublisher()
        }
    }

    public func start() {
        guard cancellable == nil else { return }
        captureStartTime = now().addingTimeInterval(-1)

        cancellable = tickPublisher
            .sink { [weak self] _ in
                self?.pollOnce()
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func pollOnce() {
        guard let directoryURL = resolveDirectoryURL() else { return }

        if currentDirectoryURL?.path != directoryURL.path {
            currentDirectoryURL = directoryURL
            seenPaths.removeAll()
            captureStartTime = now().addingTimeInterval(-1)
            PastaLogger.clipboard.info("Screenshot directory set to \(directoryURL.path)")
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to list screenshot directory")
            return
        }

        for url in urls {
            let path = url.path
            if seenPaths.contains(path) { continue }

            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else {
                seenPaths.insert(path)
                continue
            }

            guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
                seenPaths.insert(path)
                continue
            }

            guard isScreenshotFile(url) else {
                seenPaths.insert(path)
                continue
            }

            if let creationDate = values.creationDate, creationDate < captureStartTime {
                seenPaths.insert(path)
                continue
            }

            if let size = values.fileSize, size == 0 {
                continue
            }

            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Failed to read screenshot file at \(path)")
                continue
            }

            let timestamp = values.creationDate ?? values.contentModificationDate ?? now()
            let entry = ClipboardEntry(
                content: url.lastPathComponent,
                contentType: .screenshot,
                rawData: data,
                timestamp: timestamp
            )

            PastaLogger.clipboard.debug("Captured screenshot file \(url.lastPathComponent)")
            subject.send(entry)
            seenPaths.insert(path)
        }
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
        if let meta = screenshotMetadataFlag(for: url) {
            return meta
        }

        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.contains("screen shot") || name.contains("screenshot")
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
