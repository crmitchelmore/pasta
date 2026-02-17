#if os(macOS)
import AppKit
import Carbon
import Foundation

/// A hotkey binding: a key code plus modifier flags.
/// Stored as JSON in UserDefaults.
public struct PastaHotKey: Codable, Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Modifier flags stored as a Codable, Sendable, Hashable option set.
    public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt

        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let command = ModifierSet(rawValue: 1 << 0)
        public static let option = ModifierSet(rawValue: 1 << 1)
        public static let shift = ModifierSet(rawValue: 1 << 2)
        public static let control = ModifierSet(rawValue: 1 << 3)

        public init(from nsFlags: NSEvent.ModifierFlags) {
            var raw: UInt = 0
            if nsFlags.contains(.command) { raw |= ModifierSet.command.rawValue }
            if nsFlags.contains(.option) { raw |= ModifierSet.option.rawValue }
            if nsFlags.contains(.shift) { raw |= ModifierSet.shift.rawValue }
            if nsFlags.contains(.control) { raw |= ModifierSet.control.rawValue }
            self.init(rawValue: raw)
        }

        public var carbonFlags: UInt32 {
            var carbon: UInt32 = 0
            if contains(.command) { carbon |= UInt32(cmdKey) }
            if contains(.option) { carbon |= UInt32(optionKey) }
            if contains(.shift) { carbon |= UInt32(shiftKey) }
            if contains(.control) { carbon |= UInt32(controlKey) }
            return carbon
        }

        public var displayString: String {
            var parts: [String] = []
            if contains(.control) { parts.append("⌃") }
            if contains(.option) { parts.append("⌥") }
            if contains(.shift) { parts.append("⇧") }
            if contains(.command) { parts.append("⌘") }
            return parts.joined()
        }
    }

    /// Human-readable display string (e.g. "⌃⌘V").
    public var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMapping.string(for: keyCode))
        return parts.joined()
    }

    /// Default hotkey: ⌃⌘V
    public static let defaultHotKey = PastaHotKey(keyCode: 9, modifiers: [.control, .command])

    // MARK: - UserDefaults persistence

    private static let storageKey = "pasta.hotKey"

    public static func load() -> PastaHotKey {
        migrateFromKeyboardShortcutsIfNeeded()

        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let hotKey = try? JSONDecoder().decode(PastaHotKey.self, from: data)
        else {
            return .defaultHotKey
        }
        return hotKey
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: PastaHotKey.storageKey)
    }

    public static func reset() {
        defaultHotKey.save()
    }

    // MARK: - Migration from KeyboardShortcuts

    private static let migrationKey = "pasta.hotKey.migratedFromKeyboardShortcuts"

    private static func migrateFromKeyboardShortcutsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationKey)

        // KeyboardShortcuts stores as JSON string: {"carbonKeyCode":9,"carbonModifiers":4352}
        guard let json = UserDefaults.standard.string(forKey: "KeyboardShortcuts_openPasta"),
              let data = json.data(using: .utf8)
        else { return }

        struct LegacyShortcut: Decodable {
            let carbonKeyCode: Int
            let carbonModifiers: Int
        }

        guard let legacy = try? JSONDecoder().decode(LegacyShortcut.self, from: data) else { return }

        // Convert Carbon modifier flags to our ModifierSet
        var mods: ModifierSet = []
        if legacy.carbonModifiers & Int(cmdKey) != 0 { mods.insert(.command) }
        if legacy.carbonModifiers & Int(optionKey) != 0 { mods.insert(.option) }
        if legacy.carbonModifiers & Int(shiftKey) != 0 { mods.insert(.shift) }
        if legacy.carbonModifiers & Int(controlKey) != 0 { mods.insert(.control) }

        let hotKey = PastaHotKey(keyCode: UInt16(legacy.carbonKeyCode), modifiers: mods)
        hotKey.save()
    }
}

#endif
