import SwiftUI
import PastaSync

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            syncSection
            helpSection
            aboutSection
            dangerSection
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("settings.list")
        .navigationTitle("Settings")
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section("Sync") {
            Toggle("Enable iCloud Sync", isOn: Binding(
                get: { appState.isICloudSyncEnabled },
                set: { appState.setICloudSyncEnabled($0, syncManager: syncManager) }
            ))
            .accessibilityIdentifier("settings.iCloudConsent")
            Text("Enabling sync uploads your existing and future clipboard history to your private iCloud account and downloads history from your Mac. Turning it off keeps local history and stops further transfers; data already uploaded stays in iCloud.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.iCloudConsentExplanation")

            HStack {
                Label("iCloud Status", systemImage: "icloud")
                Spacer()
                Text(!appState.isICloudSyncEnabled ? "Off" : (appState.isCheckingSync ? "Checking…" : appState.iCloudStatus.label))
                    .foregroundStyle(appState.iCloudAvailable ? Color.green : Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.iCloudStatus")

            if let guidance = appState.iCloudStatus.guidance {
                Text(guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.iCloudGuidance")
            }
            if let error = appState.syncErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.syncError")
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
                    .accessibilityIdentifier("settings.entryCount")
            }

            Button {
                Task {
                    await appState.performSync(syncManager: syncManager)
                }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(!appState.isICloudSyncEnabled || appState.isCheckingSync || syncManager.syncState == .syncing)
            .accessibilityIdentifier("settings.syncNow")
        }
    }

    // MARK: - Help Section

    private var helpSection: some View {
        Section {
            Button {
                appState.replayOnboarding()
            } label: {
                Label("Replay Walkthrough", systemImage: "sparkles")
            }
            .accessibilityIdentifier("settings.replayWalkthrough")

            Button {
                appState.showWhatsNew()
            } label: {
                Label("What’s New", systemImage: "star.bubble")
            }
            .accessibilityIdentifier("settings.whatsNew")
        } header: {
            Text("Help")
        } footer: {
            Text("Use Replay Walkthrough to re-open onboarding and share what Pasta on iPhone is for.")
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
                    .accessibilityIdentifier("settings.version")
            }
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                Task {
                    await appState.resetSync(syncManager: syncManager)
                }
            } label: {
                Label("Reset Sync", systemImage: "arrow.counterclockwise")
            }
            .disabled(appState.isCheckingSync || syncManager.syncState == .syncing)
        } footer: {
            Text("Clears the sync token and forces a full re-sync from iCloud.")
        }
    }
}
