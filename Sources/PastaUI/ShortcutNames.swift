import Foundation

/// Human-readable keyboard shortcut labels shared by the main panel's footer
/// hint strip and onboarding quick-reference card, so the same gesture is
/// always described the same way.
///
/// Hotkey *storage* moved to PastaHotKey; this file only holds display names.
public enum ShortcutHints {
    public struct Hint: Equatable, Sendable {
        public let keys: String
        public let action: String

        public init(keys: String, action: String) {
            self.keys = keys
            self.action = action
        }

        /// "↩ Paste"
        public var label: String { "\(keys) \(action)" }
    }

    public static let paste = Hint(keys: "↩", action: "Paste")
    public static let pastePlainText = Hint(keys: "⇧↩", action: "Plain text")
    public static let delete = Hint(keys: "⌘⌫", action: "Delete")
    public static let filter = Hint(keys: "⌘P", action: "Filter")
    public static let search = Hint(keys: "⌘F", action: "Search")

    /// Hints shown in the main panel footer, in display order.
    public static let mainPanelFooter: [Hint] = [paste, pastePlainText, delete, filter, search]

    /// Joins hints into a single-line strip: "↩ Paste · ⇧↩ Plain text · …".
    public static func footerText(_ hints: [Hint] = mainPanelFooter) -> String {
        hints.map(\.label).joined(separator: " · ")
    }

    /// VoiceOver-friendly version: "Return: Paste. Shift Return: Plain text. …"
    public static func footerAccessibilityText(_ hints: [Hint] = mainPanelFooter) -> String {
        hints.map { "\(spokenKeys($0.keys)): \($0.action)" }.joined(separator: ". ")
    }

    static func spokenKeys(_ keys: String) -> String {
        let names: [Character: String] = [
            "↩": "Return", "⇧": "Shift", "⌘": "Command", "⌫": "Delete",
            "⌥": "Option", "⌃": "Control", "⎋": "Escape"
        ]
        return keys.map { names[$0] ?? String($0) }.joined(separator: " ")
    }
}
