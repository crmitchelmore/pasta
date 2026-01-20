import Foundation
import os.log

#if canImport(AppKit)
import AppKit
#endif

#if canImport(HotKey)
import HotKey
#endif

#if canImport(AppKit) && canImport(HotKey)
public protocol HotKeyProtocol: AnyObject {
    var keyDownHandler: (() -> Void)? { get set }
}

extension HotKey: HotKeyProtocol {}

public protocol HotKeyProviding {
    func makeHotKey(key: Key, modifiers: NSEvent.ModifierFlags) -> HotKeyProtocol
}

public struct SystemHotKeyProvider: HotKeyProviding {
    public init() {}

    public func makeHotKey(key: Key, modifiers: NSEvent.ModifierFlags) -> HotKeyProtocol {
        HotKey(key: key, modifiers: modifiers)
    }
}

public final class HotkeyManager: ObservableObject {
    private enum Defaults {
        static let hotkeyKey = "pasta.hotkey.key"
        static let hotkeyModifiers = "pasta.hotkey.modifiers"
    }

    private let provider: HotKeyProviding
    private let onTrigger: () -> Void
    private let userDefaults: UserDefaults

    private var hotKey: HotKeyProtocol
    private var defaultsObserver: NSObjectProtocol?

    public init(
        provider: HotKeyProviding = SystemHotKeyProvider(),
        userDefaults: UserDefaults = .standard,
        onTrigger: @escaping () -> Void
    ) {
        self.provider = provider
        self.userDefaults = userDefaults
        self.onTrigger = onTrigger

        let initial = HotkeyManager.loadHotkey(from: userDefaults)
        hotKey = provider.makeHotKey(key: initial.key, modifiers: initial.modifiers)
        hotKey.keyDownHandler = onTrigger
        
        PastaLogger.hotkey.info("Hotkey registered: \(String(describing: initial.key)) with modifiers \(initial.modifiers.rawValue)")

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromUserDefaults()
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    public func reloadFromUserDefaults() {
        let pref = HotkeyManager.loadHotkey(from: userDefaults)
        hotKey = provider.makeHotKey(key: pref.key, modifiers: pref.modifiers)
        hotKey.keyDownHandler = onTrigger
        PastaLogger.hotkey.info("Hotkey reloaded: \(String(describing: pref.key))")
    }

    private static func loadHotkey(from userDefaults: UserDefaults) -> (key: Key, modifiers: NSEvent.ModifierFlags) {
        let keyString = userDefaults.string(forKey: Defaults.hotkeyKey) ?? "c"
        let key: Key
        switch keyString.lowercased() {
        case "v": key = .v
        case "p": key = .p
        case "space": key = .space
        default: key = .c
        }

        let stored = userDefaults.object(forKey: Defaults.hotkeyModifiers) as? NSNumber
        let raw = stored?.uintValue ?? NSEvent.ModifierFlags([.control, .command]).rawValue
        let modifiers = NSEvent.ModifierFlags(rawValue: raw)

        return (key, modifiers)
    }
}
#else
public final class HotkeyManager {
    public init(onTrigger: @escaping () -> Void) {
        _ = onTrigger
    }
}
#endif
