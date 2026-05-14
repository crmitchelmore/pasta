import AppKit
import Foundation

import PastaCore
import PastaUI

extension AppDelegate {
    func registerHotKey() {
        let hotKey = PastaHotKey.load()
        hotKeyManager.onHotKey = { [weak self] in
            PastaLogger.app.debug("Hotkey triggered, toggling quick search")
            Task { @MainActor in
                self?.toggleQuickSearch()
            }
        }
        hotKeyManager.register(hotKey)
    }

    func observeHotKeyNotifications() {
        hotKeyPauseObserver = NotificationCenter.default.addObserver(
            forName: .pastaHotKeyShouldPause, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hotKeyManager.unregister()
            }
        }
        hotKeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .pastaHotKeyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotKey()
            }
        }
    }

    func toggleQuickSearch() {
        // Just toggle - content and data are pre-warmed
        quickSearchController?.toggle()
    }
}
