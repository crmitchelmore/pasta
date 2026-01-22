import Foundation
import KeyboardShortcuts
import os.log

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Shortcut Name Registration

public extension KeyboardShortcuts.Name {
    /// Global shortcut to open Pasta quick search
    static let openPasta = Self("openPasta", default: .init(.c, modifiers: [.control, .command]))
}

// MARK: - Hotkey Manager

#if canImport(AppKit)
public final class HotkeyManager: ObservableObject {
    private let onTrigger: () -> Void
    
    public init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        
        // Register the callback for when the shortcut is pressed
        KeyboardShortcuts.onKeyUp(for: .openPasta) { [weak self] in
            PastaLogger.hotkey.debug("KeyboardShortcuts triggered")
            self?.onTrigger()
        }
        
        PastaLogger.hotkey.info("KeyboardShortcuts registered for openPasta")
    }
    
    /// Force reload shortcut (called when settings change)
    public func reloadFromUserDefaults() {
        // KeyboardShortcuts automatically persists and reloads
        // This method is kept for API compatibility
        PastaLogger.hotkey.info("Hotkey reloaded via KeyboardShortcuts")
    }
}
#else
public final class HotkeyManager {
    public init(onTrigger: @escaping () -> Void) {
        _ = onTrigger
    }
    
    public func reloadFromUserDefaults() {}
}
#endif
