#if os(macOS)
import Foundation

/// Represents a clipboard app that can be imported from
public enum ClipboardApp: String, CaseIterable, Identifiable {
    case alfred = "Alfred"
    case maccy = "Maccy"
    case flycut = "Flycut"
    case copyClip = "CopyClip"
    case paste = "Paste"
    case pastebot = "Pastebot"
    case clipy = "Clipy"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .alfred: return "sparkle.magnifyingglass"
        case .maccy: return "doc.on.clipboard"
        case .flycut: return "scissors"
        case .copyClip: return "paperclip"
        case .paste: return "doc.on.doc"
        case .pastebot: return "robot"
        case .clipy: return "clipboard"
        }
    }

    public var description: String {
        switch self {
        case .alfred: return "Alfred Clipboard History"
        case .maccy: return "Maccy (open source)"
        case .flycut: return "Flycut (open source)"
        case .copyClip: return "CopyClip / CopyClip 2"
        case .paste: return "Paste by Widetape"
        case .pastebot: return "Pastebot by Tapbots"
        case .clipy: return "Clipy (open source)"
        }
    }

    /// Check if this app's data is available for import
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }

    var databasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .alfred:
            return "\(home)/Library/Application Support/Alfred/Databases/clipboard.alfdb"
        case .maccy:
            return "\(home)/Library/Application Support/Maccy/Storage.sqlite"
        case .flycut:
            return "\(home)/Library/Preferences/net.sogao.Flycut.plist"
        case .copyClip:
            return "\(home)/Library/Application Support/com.fiplab.copyclip2/Data/com.fiplab.copyclip2.data"
        case .paste:
            return "\(home)/Library/Containers/com.widetape.Paste/Data/Library/Application Support/Paste/Paste.sqlite"
        case .pastebot:
            return "\(home)/Library/Group Containers/9272N75U7L.com.tapbots.Pastebot/Pastebot.sqlite"
        case .clipy:
            return "\(home)/Library/Application Support/com.clipy-app.Clipy/default.realm"
        }
    }
}
#endif
