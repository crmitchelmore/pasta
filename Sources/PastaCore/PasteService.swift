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
    public init() {}

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

        // Post events with small delay between for reliability
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

public final class PasteService {
    public enum Contents: Equatable {
        case text(String)
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
    private static let restoreDelayMs = 300

    public init(
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        simulator: PasteEventSimulating = SystemPasteEventSimulator(),
        restoreClipboard: Bool = false
    ) {
        self.pasteboard = pasteboard
        self.simulator = simulator
        self.restoreClipboard = restoreClipboard
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

    /// Copies the entry to the system pasteboard, then simulates Cmd+V.
    /// Returns false if the entry cannot be represented on the pasteboard.
    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        guard let contents = makeContents(for: entry) else {
            PastaLogger.clipboard.warning("Cannot create pasteboard contents for entry type \(entry.contentType.rawValue)")
            return false
        }
        
        // Save current clipboard contents if restore is enabled
        let savedContents = restoreClipboard ? pasteboard.saveCurrentContents() : nil
        
        pasteboard.write(contents)

        if AccessibilityPermission.isTrusted() {
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
    public func copy(_ entry: ClipboardEntry) -> Bool {
        _ = entry
        return false
    }

    @discardableResult
    public func paste(_ entry: ClipboardEntry) -> Bool {
        _ = entry
        return false
    }
}
#endif
