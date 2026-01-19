import Foundation
import Combine

#if canImport(AppKit)
import AppKit
#endif

public enum PasteboardContents: Equatable {
    case text(String)
    case rtf(String)
    case image(Data)
    case filePaths([String])
}

public protocol PasteboardProviding {
    var changeCount: Int { get }
    func readContents() -> PasteboardContents?
}

public protocol WorkspaceProviding {
    func frontmostApplicationIdentifier() -> String?
}

#if canImport(AppKit)
public struct SystemPasteboard: PasteboardProviding {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func readContents() -> PasteboardContents? {
        if let data = pasteboard.data(forType: .tiff) {
            return .image(data)
        }

        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !objects.isEmpty {
            return .filePaths(objects.map { $0.path })
        }

        if let rtfData = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return .rtf(attributed.string)
        }

        if let string = pasteboard.string(forType: .string) {
            return .text(string)
        }

        return nil
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
    private let tickPublisher: AnyPublisher<Void, Never>
    private let now: () -> Date

    private let subject = PassthroughSubject<ClipboardEntry, Never>()
    private var cancellable: AnyCancellable?

    private var lastSeenChangeCount: Int?
    private var lastEmittedContents: PasteboardContents?

    public init(
        pasteboard: PasteboardProviding,
        workspace: WorkspaceProviding? = nil,
        pollInterval: TimeInterval = 0.5,
        tickPublisher: AnyPublisher<Void, Never>? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
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
        self.init(pasteboard: SystemPasteboard(), workspace: SystemWorkspace(), pollInterval: pollInterval)
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

        guard let contents = pasteboard.readContents() else { return }
        if contents == lastEmittedContents { return }
        lastEmittedContents = contents

        let entry = ClipboardEntry(
            content: contentString(for: contents),
            contentType: contentType(for: contents),
            rawData: rawData(for: contents),
            timestamp: now(),
            sourceApp: workspace?.frontmostApplicationIdentifier()
        )

        subject.send(entry)
    }

    private func contentType(for contents: PasteboardContents) -> ContentType {
        switch contents {
        case .text, .rtf:
            return .text
        case .image:
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
