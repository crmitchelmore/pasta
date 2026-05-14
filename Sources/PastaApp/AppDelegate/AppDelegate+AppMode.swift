import AppKit
import Foundation

extension AppDelegate {
    enum Defaults {
        static let appMode = "pasta.appMode"
    }

    enum AppMode: String {
        case menuBar
        case dock
        case both
    }

    func observeDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.applyAppMode()
            }
        }
    }

    func applyAppMode() {
        let raw = UserDefaults.standard.string(forKey: Defaults.appMode) ?? AppMode.both.rawValue
        let mode = AppMode(rawValue: raw) ?? .both

        switch mode {
        case .menuBar:
            NSApplication.shared.setActivationPolicy(.accessory)
            updateStatusItem(enabled: true)
        case .dock:
            NSApplication.shared.setActivationPolicy(.regular)
            updateStatusItem(enabled: false)
        case .both:
            NSApplication.shared.setActivationPolicy(.regular)
            updateStatusItem(enabled: true)
        }
    }
}
