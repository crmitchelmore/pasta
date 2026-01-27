import Foundation
import Combine
import os.log

#if canImport(AppKit)
import AppKit
#endif

public enum PasteboardContents: Equatable {
    case text(String)
    case rtf(String)
    case image(Data)
    case filePaths([String])
}

public struct PasteboardMetadata: Equatable {
    /// Whether the clipboard contents came from another device via Universal Clipboard/Handoff
    public let isContinuitySync: Bool
    /// The origin device name if available
    public let originDeviceName: String?
    
    public init(isContinuitySync: Bool = false, originDeviceName: String? = nil) {
        self.isContinuitySync = isContinuitySync
        self.originDeviceName = originDeviceName
    }
}

public protocol PasteboardProviding {
    var changeCount: Int { get }
    func readContents() -> PasteboardContents?
    func readMetadata() -> PasteboardMetadata
}

public protocol WorkspaceProviding {
    func frontmostApplicationIdentifier() -> String?
}

#if canImport(AppKit)
public struct SystemPasteboard: PasteboardProviding {
    private let pasteboard: NSPasteboard
    
    // Pasteboard types that indicate Universal Clipboard / Handoff
    private static let handoffTypes: Set<String> = [
        "com.apple.is-remote-clipboard",
        "com.apple.remote-clipboard.data",
        "dyn.age8u"  // Dynamic type used for Handoff
    ]

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func readContents() -> PasteboardContents? {
        // Check for file paths first (copying files in Finder)
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !objects.isEmpty {
            return .filePaths(objects.map { $0.path })
        }

        // Check for text content (RTF or plain text)
        // Do this BEFORE images because apps like Excel/Word include thumbnail images
        // alongside text, and we want to capture the text, not the preview image
        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return .rtf(attributed.string)
        }

        if let string = pasteboard.string(forType: .string) {
            return .text(string)
        }

        // Only treat as image if no text content is available
        if let data = pasteboard.data(forType: .tiff) {
            return .image(data)
        }

        return nil
    }
    
    public func readMetadata() -> PasteboardMetadata {
        // Check if clipboard contains markers indicating it came from another device
        let types = pasteboard.types ?? []
        let typeStrings = Set(types.map { $0.rawValue })
        
        let isContinuity = !typeStrings.isDisjoint(with: Self.handoffTypes) ||
            typeStrings.contains(where: { $0.contains("remote") || $0.contains("handoff") })
        
        // Try to get origin device name from pasteboard data
        var deviceName: String? = nil
        if isContinuity {
            // Apple doesn't expose device name directly, but we can mark it as synced
            deviceName = "Another device"
        }
        
        return PasteboardMetadata(isContinuitySync: isContinuity, originDeviceName: deviceName)
    }
}

public struct SystemWorkspace: WorkspaceProviding {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func frontmostApplicationIdentifier() -> String? {
        workspace.frontmostApplication?.bundleIdentifier ?? workspace.frontmostApplication?.localizedName
    }
}
#endif

public final class ClipboardMonitor {
    public var publisher: AnyPublisher<ClipboardEntry, Never> {
        subject.eraseToAnyPublisher()
    }

    private let pasteboard: PasteboardProviding
    private let workspace: WorkspaceProviding?
    private let exclusionManager: ExclusionManager
    private let tickPublisher: AnyPublisher<Void, Never>
    private let now: () -> Date

    private let subject = PassthroughSubject<ClipboardEntry, Never>()
    private var cancellable: AnyCancellable?

    private var lastSeenChangeCount: Int?
    private var lastEmittedContents: PasteboardContents?

    public init(
        pasteboard: PasteboardProviding,
        workspace: WorkspaceProviding? = nil,
        exclusionManager: ExclusionManager = ExclusionManager(),
        pollInterval: TimeInterval = 0.5,
        tickPublisher: AnyPublisher<Void, Never>? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.exclusionManager = exclusionManager
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

    #if canImport(AppKit)
    public convenience init(pollInterval: TimeInterval = 0.5) {
        self.init(pasteboard: SystemPasteboard(), workspace: SystemWorkspace(), exclusionManager: ExclusionManager(), pollInterval: pollInterval)
    }
    #endif

    public func start() {
        guard cancellable == nil else { return }
        lastSeenChangeCount = pasteboard.changeCount

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
        let changeCount = pasteboard.changeCount
        if let lastSeenChangeCount, changeCount == lastSeenChangeCount { return }
        lastSeenChangeCount = changeCount

        guard let contents = pasteboard.readContents() else {
            // If we can't read the clipboard, it might be an access issue
            PastaLogger.clipboard.warning("Failed to read clipboard contents - may be access denied")
            return
        }
        
        if contents == lastEmittedContents { return }
        lastEmittedContents = contents

        let sourceApp = workspace?.frontmostApplicationIdentifier()
        if exclusionManager.isExcluded(bundleIdentifier: sourceApp) {
            PastaLogger.clipboard.debug("Skipped entry from excluded app: \(sourceApp ?? "unknown")")
            return
        }
        
        // Check for Continuity clipboard
        let metadata = pasteboard.readMetadata()
        var entryMetadata: String? = nil
        if metadata.isContinuitySync {
            // Encode metadata as JSON
            let metaDict: [String: Any] = [
                "continuitySync": true,
                "originDevice": metadata.originDeviceName ?? "Unknown device"
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: metaDict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                entryMetadata = jsonString
            }
            PastaLogger.clipboard.info("Detected Continuity clipboard sync from \(metadata.originDeviceName ?? "another device")")
        }

        let entry = ClipboardEntry(
            content: contentString(for: contents),
            contentType: contentType(for: contents, sourceApp: sourceApp),
            rawData: rawData(for: contents),
            timestamp: now(),
            sourceApp: metadata.isContinuitySync ? "Continuity" : sourceApp,
            metadata: entryMetadata
        )

        PastaLogger.clipboard.debug("Captured clipboard entry of type \(entry.contentType.rawValue)")
        subject.send(entry)
    }

    private func contentType(for contents: PasteboardContents, sourceApp: String?) -> ContentType {
        switch contents {
        case .text, .rtf:
            return .text
        case .image:
            // Detect screenshots by source app
            if let app = sourceApp?.lowercased(),
               app.contains("screenshot") || app.contains("screencapture") {
                return .screenshot
            }
            return .image
        case .filePaths:
            return .filePath
        }
    }

    private func contentString(for contents: PasteboardContents) -> String {
        switch contents {
        case .text(let string), .rtf(let string):
            return string
        case .image:
            return ""
        case .filePaths(let paths):
            return paths.joined(separator: "\n")
        }
    }

    private func rawData(for contents: PasteboardContents) -> Data? {
        switch contents {
        case .image(let data):
            return data
        case .text, .rtf, .filePaths:
            return nil
        }
    }
}
