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

    private var hotKey: HotKeyProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var globalMonitor: Any?
    
    // Store current hotkey config for global monitor matching
    private var currentKey: Key = .c
    private var currentModifiers: NSEvent.ModifierFlags = [.control, .command]

    public init(
        provider: HotKeyProviding = SystemHotKeyProvider(),
        userDefaults: UserDefaults = .standard,
        onTrigger: @escaping () -> Void
    ) {
        self.provider = provider
        self.userDefaults = userDefaults
        self.onTrigger = onTrigger

        let initial = HotkeyManager.loadHotkey(from: userDefaults)
        currentKey = initial.key
        currentModifiers = initial.modifiers
        
        setupHotkey(key: initial.key, modifiers: initial.modifiers)
        
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
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
    
    private func setupHotkey(key: Key, modifiers: NSEvent.ModifierFlags) {
        // Primary: Use HotKey library (Carbon Event Manager)
        // Note: Carbon hotkeys work globally without accessibility permissions
        // but may not work when running via `swift run` (needs proper app bundle)
        hotKey = provider.makeHotKey(key: key, modifiers: modifiers)
        hotKey?.keyDownHandler = { [weak self] in
            PastaLogger.hotkey.debug("HotKey library triggered")
            self?.onTrigger()
        }
        
        // Fallback: Global event monitor (requires accessibility permissions)
        // This catches the hotkey when Carbon registration doesn't work
        if let oldMonitor = globalMonitor {
            NSEvent.removeMonitor(oldMonitor)
        }
        
        // Convert Key to keyCode for reliable matching
        let targetKeyCode = key.carbonKeyCode
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            
            let eventModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard eventModifiers == self.currentModifiers else { return }
            
            // Match by keyCode for reliability
            if event.keyCode == targetKeyCode {
                PastaLogger.hotkey.debug("Global monitor triggered (keyCode: \(event.keyCode))")
                DispatchQueue.main.async {
                    self.onTrigger()
                }
            }
        }
        
        PastaLogger.hotkey.debug("Global monitor installed for keyCode \(targetKeyCode) with modifiers \(modifiers.rawValue)")
    }

    public func reloadFromUserDefaults() {
        let pref = HotkeyManager.loadHotkey(from: userDefaults)
        currentKey = pref.key
        currentModifiers = pref.modifiers
        setupHotkey(key: pref.key, modifiers: pref.modifiers)
        PastaLogger.hotkey.info("Hotkey reloaded: \(String(describing: pref.key))")
    }

    private static func loadHotkey(from userDefaults: UserDefaults) -> (key: Key, modifiers: NSEvent.ModifierFlags) {
        let keyString = userDefaults.string(forKey: Defaults.hotkeyKey) ?? "c"
        let key = keyFromString(keyString) ?? .c

        let stored = userDefaults.object(forKey: Defaults.hotkeyModifiers) as? NSNumber
        let raw = stored?.uintValue ?? NSEvent.ModifierFlags([.control, .command]).rawValue
        let modifiers = NSEvent.ModifierFlags(rawValue: raw)

        return (key, modifiers)
    }
    
    private static func keyFromString(_ str: String) -> Key? {
        switch str.lowercased() {
        case "a": return .a
        case "b": return .b
        case "c": return .c
        case "d": return .d
        case "e": return .e
        case "f": return .f
        case "g": return .g
        case "h": return .h
        case "i": return .i
        case "j": return .j
        case "k": return .k
        case "l": return .l
        case "m": return .m
        case "n": return .n
        case "o": return .o
        case "p": return .p
        case "q": return .q
        case "r": return .r
        case "s": return .s
        case "t": return .t
        case "u": return .u
        case "v": return .v
        case "w": return .w
        case "x": return .x
        case "y": return .y
        case "z": return .z
        case "0": return .zero
        case "1": return .one
        case "2": return .two
        case "3": return .three
        case "4": return .four
        case "5": return .five
        case "6": return .six
        case "7": return .seven
        case "8": return .eight
        case "9": return .nine
        case "space": return .space
        case "`": return .grave
        case "-": return .minus
        case "=": return .equal
        case "[": return .leftBracket
        case "]": return .rightBracket
        case "\\": return .backslash
        case ";": return .semicolon
        case "'": return .quote
        case ",": return .comma
        case ".": return .period
        case "/": return .slash
        default: return nil
        }
    }
}
#else
public final class HotkeyManager {
    public init(onTrigger: @escaping () -> Void) {
        _ = onTrigger
    }
}
#endif
