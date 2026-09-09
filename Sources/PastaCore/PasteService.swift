import Foundation
import os.log

#if canImport(AppKit)
import AppKit
#endif

#if canImport(ApplicationServices)
import ApplicationServices
#endif

#if canImport(AppKit) && canImport(ApplicationServices)
public protocol PasteboardWriting {
    func write(_ contents: PasteService.Contents)
    func saveCurrentContents() -> PasteService.SavedContents?
    func restore(_ contents: PasteService.SavedContents)
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
        case .richText(let string, let data):
            pasteboard.setString(string, forType: .string)
            pasteboard.setData(data, forType: .rtf)

        case .imageTIFF(let data):
            pasteboard.setData(data, forType: .tiff)

        case .fileURLs(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }
    }
    
    public func saveCurrentContents() -> PasteService.SavedContents? {
        if let string = pasteboard.string(forType: .string) {
            return .text(string)
        } else if let data = pasteboard.data(forType: .tiff) {
            return .imageTIFF(data)
        }
        return nil
    }
    
    public func restore(_ contents: PasteService.SavedContents) {
        pasteboard.clearContents()
        switch contents {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .imageTIFF(let data):
            pasteboard.setData(data, forType: .tiff)
        }
    }
}

public protocol PasteEventSimulating {
    func simulateCommandV()
}

public struct SystemPasteEventSimulator: PasteEventSimulating {
    public static let syntheticEventMarker: Int64 = 0x5041535441
    public init() {}

    public func moveCursorLeft(by count: Int) {
        guard count > 0, AccessibilityPermission.isTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: down)
                event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    public func simulateCommandV() {
        // Requires Accessibility permissions.
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            PastaLogger.clipboard.warning("Failed to create CGEventSource")
            return
        }
        
        let keyCodeV: CGKeyCode = 9

        // Create key down event
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true) else {
            PastaLogger.clipboard.warning("Failed to create keyDown event")
            return
        }
        keyDown.flags = .maskCommand

        // Create key up event
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false) else {
            PastaLogger.clipboard.warning("Failed to create keyUp event")
            return
        }
        keyUp.flags = .maskCommand

        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)

        // Post events with small delay between for reliability
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

public final class PasteService {
    public enum Contents: Equatable {
        case text(String)
        case richText(String, Data)
        case imageTIFF(Data)
        case fileURLs([URL])
    }
    
    public enum SavedContents {
        case text(String)
        case imageTIFF(Data)
    }

    private let pasteboard: PasteboardWriting
    private let simulator: PasteEventSimulating
    private let restoreClipboard: Bool
    private let isAccessibilityTrusted: () -> Bool
    private static let restoreDelayMs = 300

    public init(
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        simulator: PasteEventSimulating = SystemPasteEventSimulator(),
        restoreClipboard: Bool = false,
        isAccessibilityTrusted: @escaping () -> Bool = AccessibilityPermission.isTrusted
    ) {
        self.pasteboard = pasteboard
        self.simulator = simulator
        self.restoreClipboard = restoreClipboard
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    /// Copies the entry to the system pasteboard without simulating Cmd+V.
    @discardableResult
    public func copy(_ entry: ClipboardEntry) -> Bool {
        guard let contents = makeContents(for: entry) else {
            PastaLogger.clipboard.warning("Cannot create pasteboard contents for entry type \(entry.contentType.rawValue)")
            return false
        }

        pasteboard.write(contents)
        PastaLogger.clipboard.debug("Copied entry of type \(entry.contentType.rawValue)")
        return true
    }

    /// Copies multiple entry values to the system pasteboard as joined text.
    /// Single-item selections preserve the normal copy behaviour for that entry type.
    @discardableResult
    public func copy(_ entries: [ClipboardEntry], joinedBy separator: String) -> Bool {
        guard !entries.isEmpty else {
            PastaLogger.clipboard.warning("Cannot copy an empty entry selection")
            return false
        }

        if entries.count == 1, let entry = entries.first {
            return copy(entry)
        }

        let joinedContent = entries.map(\.content).joined(separator: separator)
        pasteboard.write(.text(joinedContent))
        PastaLogger.clipboard.debug("Copied \(entries.count) joined entries")
        return true
    }

    /// Copies the entry to the system pasteboard, then simulates Cmd+V.
    /// Returns false if the entry cannot be represented on the pasteboard.
    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        return paste(entry, asPlainText: false)
    }

    /// Like `paste(_:)` but always writes the entry's text content as a plain UTF-8
    /// string, regardless of the entry's content type. Useful when the original was
    /// captured as RTF/file-URL/image and the user wants to drop formatting.
    /// For binary types (image / screenshot) with no textual representation this
    /// returns false without touching the pasteboard.
    @discardableResult
    public func pastePlainText(_ entry: ClipboardEntry) -> Bool {
        return paste(entry, asPlainText: true)
    }

    @discardableResult
    private func paste(_ entry: ClipboardEntry, asPlainText: Bool) -> Bool {
        let contents: Contents?
        if asPlainText {
            let text = entry.content
            contents = text.isEmpty ? nil : .text(text)
        } else {
            contents = makeContents(for: entry)
        }
        guard let contents else {
            PastaLogger.clipboard.warning("Cannot create pasteboard contents for entry type \(entry.contentType.rawValue) (plain=\(asPlainText))")
            return false
        }
        
        // Save current clipboard contents if restore is enabled
        let savedContents = restoreClipboard ? pasteboard.saveCurrentContents() : nil
        
        pasteboard.write(contents)

        if isAccessibilityTrusted() {
            simulator.simulateCommandV()
            
            // Schedule clipboard restore if enabled
            if restoreClipboard, let savedContents {
                scheduleClipboardRestore(savedContents)
            }
        } else {
            PastaLogger.clipboard.warning("Accessibility permission not granted; copied to clipboard but cannot simulate Cmd+V")
        }

        PastaLogger.clipboard.debug("Pasted entry of type \(entry.contentType.rawValue)")
        return true
    }
    
    private func scheduleClipboardRestore(_ contents: SavedContents) {
        let delay = DispatchTime.now() + .milliseconds(Self.restoreDelayMs)
        let pasteboardRef = pasteboard
        DispatchQueue.main.asyncAfter(deadline: delay) {
            pasteboardRef.restore(contents)
            PastaLogger.clipboard.debug("Restored previous clipboard contents")
        }
    }

    private func makeContents(for entry: ClipboardEntry) -> Contents? {
        switch entry.contentType {
        case .image, .screenshot:
            // Try rawData first, then load from imagePath if needed
            if let data = entry.rawData {
                return .imageTIFF(data)
            } else if let imagePath = entry.imagePath,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
                return .imageTIFF(data)
            }
            return nil

        case .filePath:
            let paths = entry.filePaths
            let urls = paths.map { URL(fileURLWithPath: $0) }
            return urls.isEmpty ? nil : .fileURLs(urls)

        default:
            if let data = entry.rawData, data.starts(with: Data("{\\rtf".utf8)) {
                return .richText(entry.content, data)
            }
            return .text(entry.content)
        }
    }
}
#else
public final class PasteService {
    public init() {}

    @discardableResult
    public func copy(_ entry: ClipboardEntry) -> Bool {
        _ = entry
        return false
    }

    @discardableResult
    public func copy(_ entries: [ClipboardEntry], joinedBy separator: String) -> Bool {
        _ = entries
        _ = separator
        return false
    }

    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        _ = entry
        return false
    }
}
#endif
