import SwiftUI
import PastaSync

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            syncSection
            aboutSection
            dangerSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section("Sync") {
            HStack {
                Label("iCloud Status", systemImage: "icloud")
                Spacer()
                if appState.iCloudAvailable {
                    Text("Connected")
                        .foregroundStyle(.green)
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.red)
                }
            }

            if let lastSync = syncManager.lastSyncDate {
                HStack {
                    Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("Entries", systemImage: "doc.on.doc")
                Spacer()
                Text("\(appState.entries.count)")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await appState.performSync(syncManager: syncManager)
                }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(syncManager.syncState == .syncing)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                syncManager.resetSync()
                Task {
                    await appState.performSync(syncManager: syncManager)
                }
            } label: {
                Label("Reset Sync", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("Clears the sync token and forces a full re-sync from iCloud.")
        }
    }
}
