import SwiftUI
import PastaSync
import UIKit

struct SettingsView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState
    @State private var isConfirmingReset = false
    @State private var isShowingDiagnostics = false

    var body: some View {
        List {
            syncSection
            helpSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("settings.list")
        .navigationTitle("Settings")
        .alert("Reset iCloud Sync?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Sync") {
                Task { await appState.resetSync(syncManager: syncManager) }
            }
            .accessibilityIdentifier("settings.confirmResetSync")
        } message: {
            Text("Your local history and iCloud data are kept. Pasta will download iCloud history again when sync is enabled and connected.")
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            SyncDiagnosticsSheet {
                await appState.syncDiagnosticReport(syncManager: syncManager)
            }
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section("Sync") {
            Toggle("Enable iCloud Sync", isOn: Binding(
                get: { appState.isICloudSyncEnabled },
                set: { appState.setICloudSyncEnabled($0, syncManager: syncManager) }
            ))
            .accessibilityIdentifier("settings.iCloudConsent")
            Text("Uploads existing and future clipboard history to your private iCloud account and downloads history from your Mac. Turning sync off stops transfers; local history and uploaded iCloud data are kept.")
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

            syncFeedback

            Button {
                Task { await appState.performSync(syncManager: syncManager) }
            } label: {
                Label(appState.isCheckingSync ? "Syncing…" : "Sync Now", systemImage: "arrow.clockwise")
            }
            .disabled(!appState.isICloudSyncEnabled || syncIsBusy)
            .accessibilityIdentifier("settings.syncNow")

            Button {
                isConfirmingReset = true
            } label: {
                Label(appState.isResettingSync ? "Resetting…" : "Reset Sync", systemImage: "arrow.counterclockwise")
            }
            .disabled(syncIsBusy)
            .accessibilityIdentifier("settings.resetSync")

            Button {
                isShowingDiagnostics = true
            } label: {
                Label("Sync Diagnostics…", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("settings.syncDiagnostics")

            if let lastSync = syncManager.lastSyncDate {
                HStack {
                    Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("Local Entries", systemImage: "doc.on.doc")
                Spacer()
                Text("\(appState.entries.count)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.entryCount")
            }

        }
    }

    private var syncIsBusy: Bool {
        appState.isCheckingSync || appState.isResettingSync || syncManager.syncState == .syncing
    }

    @ViewBuilder
    private var syncFeedback: some View {
        if let error = appState.syncErrorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings.syncError")
        } else if let message = appState.syncFeedbackMessage {
            HStack(spacing: 10) {
                if syncIsBusy {
                    ProgressView()
                        .accessibilityLabel("Sync in progress")
                        .accessibilityIdentifier("settings.syncProgress")
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.syncFeedback")
            }
        } else if let guidance = appState.iCloudStatus.guidance {
            Text(guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.iCloudGuidance")
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

}

/// Diagnostics never grant sync consent or start a sync; only Copy writes to the clipboard.
private struct SyncDiagnosticsSheet: View {
    let collectReport: @MainActor () async -> String
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var isLoading = true
    @State private var refreshID = 0
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Compare this report with your other device. Clipboard contents are excluded; local and iCloud history are unchanged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isLoading {
                    ProgressView("Checking iCloud and local history…")
                        .accessibilityIdentifier("syncDiagnostics.progress")
                }

                ScrollView {
                    Text(report)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("syncDiagnostics.report")
                }

                HStack {
                    Button("Refresh") {
                        isLoading = true
                        refreshID += 1
                    }
                    .accessibilityIdentifier("syncDiagnostics.refresh")
                    Spacer()
                    Button(didCopy ? "Copied" : "Copy Report") {
                        UIPasteboard.general.string = report
                        didCopy = true
                    }
                    .disabled(report.isEmpty)
                    .accessibilityIdentifier("syncDiagnostics.copy")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }
            .padding()
            .navigationTitle("Sync Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("syncDiagnostics.done")
                }
            }
            .task(id: refreshID) {
                didCopy = false
                let refreshedReport = await collectReport()
                guard !Task.isCancelled else { return }
                report = refreshedReport
                isLoading = false
            }
        }
    }
}
