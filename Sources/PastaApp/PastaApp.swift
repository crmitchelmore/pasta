import AppKit
import SwiftUI

import PastaCore

@main
struct PastaApp: App {
    // Keep this alive for the lifetime of the app.
    private let hotkeyManager: HotkeyManager

    init() {
        // Menu-bar-only experience (no Dock icon).
        NSApplication.shared.setActivationPolicy(.accessory)

        hotkeyManager = HotkeyManager {
            // Best-effort: make the app active so the user can interact with the menu bar popover.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
        } label: {
            Image("MenuBarIcon", bundle: .module)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}

private struct PopoverRootView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pasta")
                .font(.headline)

            Text("Clipboard history app (UI in progress).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button("Close") {
                dismiss()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 360)
    }
}
