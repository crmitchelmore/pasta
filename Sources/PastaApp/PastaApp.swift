import AppKit
import SwiftUI

import PastaCore
import PastaUI

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

    @State private var entries: [ClipboardEntry] = []

    private let database: DatabaseManager = {
        // UI fallback if the on-disk DB can't be created for any reason.
        (try? DatabaseManager()) ?? (try! DatabaseManager.inMemory())
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pasta")
                    .font(.headline)

                Spacer()

                Button("Close") { dismiss() }
            }

            ClipboardListView(entries: entries)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Refresh") {
                    entries = (try? database.fetchRecent(limit: 1_000)) ?? []
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 520, height: 640)
        .onAppear {
            entries = (try? database.fetchRecent(limit: 1_000)) ?? []
        }
    }
}
