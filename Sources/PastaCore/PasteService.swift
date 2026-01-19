import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(ApplicationServices)
import ApplicationServices
#endif

#if canImport(AppKit) && canImport(ApplicationServices)
public protocol PasteboardWriting {
    func write(_ contents: PasteService.Contents)
}

public struct SystemPasteboardWriter: PasteboardWriting {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func write(_ contents: PasteService.Contents) {
        pasteboard.clearContents()

        switch contents {
        case .text(let string):
            pasteboard.setString(string, forType: .string)

        case .imageTIFF(let data):
            pasteboard.setData(data, forType: .tiff)

        case .fileURLs(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
    }
}

public protocol PasteEventSimulating {
    func simulateCommandV()
}

public struct SystemPasteEventSimulator: PasteEventSimulating {
    public init() {}

    public func simulateCommandV() {
        // Best-effort. Requires Accessibility permissions.
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCodeV: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

public final class PasteService {
    public enum Contents: Equatable {
        case text(String)
        case imageTIFF(Data)
        case fileURLs([URL])
    }

    private let pasteboard: PasteboardWriting
    private let simulator: PasteEventSimulating

    public init(
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        simulator: PasteEventSimulating = SystemPasteEventSimulator()
    ) {
        self.pasteboard = pasteboard
        self.simulator = simulator
    }

    /// Copies the entry to the system pasteboard, then simulates Cmd+V.
    /// Returns false if the entry cannot be represented on the pasteboard.
    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        guard let contents = makeContents(for: entry) else { return false }
        pasteboard.write(contents)
        simulator.simulateCommandV()
        return true
    }

    private func makeContents(for entry: ClipboardEntry) -> Contents? {
        switch entry.contentType {
        case .image:
            guard let data = entry.rawData else { return nil }
            return .imageTIFF(data)

        case .filePath:
            let paths = entry.content
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }

            let urls = paths.map { URL(fileURLWithPath: $0) }
            return urls.isEmpty ? nil : .fileURLs(urls)

        default:
            return .text(entry.content)
        }
    }
}
#else
public final class PasteService {
    public init() {}

    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        _ = entry
        return false
    }
}
#endif
