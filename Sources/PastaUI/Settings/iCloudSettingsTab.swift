import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - iCloud Settings Tab

struct iCloudSettingsTab: View {
    @ObservedObject var syncManager: SyncManager
    let syncNow: (@MainActor () async throws -> Void)?
    let resetSync: (@MainActor () throws -> Void)?
    @State private var isSyncing = false
    @State private var syncError: String?
    let syncedCount: () -> Int
    @State private var iCloudAvailable: Bool? = nil
    @State private var isResetting = false
    @State private var displayedSyncedCount: Int = 0
    let diagnosticReport: @MainActor () async -> String
    @State private var isShowingDiagnostics = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("iCloud Status")
                    Spacer()
                    statusBadge
                }

                if let lastSync = syncManager.lastSyncDate {
                    LabeledContent("Last Synced") {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Local Entries Marked Synced") {
                    Text("\(displayedSyncedCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if syncManager.syncState == .syncing && syncManager.totalEntriesToSync > 0 {
                    LabeledContent("Upload Progress") {
                        Text("\(syncManager.syncedEntryCount) / \(syncManager.totalEntriesToSync)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Text("The entry count describes history on this Mac. Open Sync Diagnostics to compare it with iCloud and your other devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Status", systemImage: "icloud")
            }

            Section {
                if syncManager.syncState == .syncing && syncManager.totalEntriesToSync > 50 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Syncing \(syncManager.syncedEntryCount) of \(syncManager.totalEntriesToSync)")
                                .font(.subheadline)
                                .monospacedDigit()
                            Spacer()
                            Button("Cancel") {
                                syncManager.cancelSync()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        ProgressView(
                            value: Double(syncManager.syncedEntryCount),
                            total: Double(max(syncManager.totalEntriesToSync, 1))
                        )
                        .progressViewStyle(.linear)
                        Text("Uploading clipboard history to iCloud. You can cancel and resume later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if isSyncing || syncManager.syncState == .syncing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        Button("Sync") {
                            guard let syncNow, !isSyncing else { return }
                            isSyncing = true
                            syncError = nil
                            Task { @MainActor in
                                defer {
                                    isSyncing = false
                                    displayedSyncedCount = syncedCount()
                                }
                                do {
                                    try await syncNow()
                                } catch {
                                    syncError = error.localizedDescription
                                }
                            }
                        }
                        .disabled(syncNow == nil || iCloudAvailable != true)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if let syncError {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if case .error(let message) = syncManager.syncState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Pasta syncs clipboard history via iCloud so you can access it on all your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            Section {
                HStack {
                    Text("Inspect iCloud Connection")
                    Spacer()
                    Button("Sync Diagnostics…") {
                        isShowingDiagnostics = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.syncDiagnostics")
                }

                Text("View connection details and history counts without changing local or iCloud history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Reset Sync…") {
                        isResetting = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(resetSync == nil || isSyncing || syncManager.syncState == .syncing)
                    Spacer()
                }

                Text("Reset Sync keeps all local and iCloud history and downloads iCloud history again on the next sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            displayedSyncedCount = syncedCount()
        }
        .onChange(of: syncManager.syncState) { _, newState in
            if newState == .idle {
                displayedSyncedCount = syncedCount()
            }
        }
        .task {
            let status = try? await syncManager.checkAccountStatus()
            iCloudAvailable = (status == .available)
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            SyncDiagnosticsSheet(collectReport: diagnosticReport)
        }
        .confirmationDialog(
            "Reset iCloud Sync?",
            isPresented: $isResetting,
            titleVisibility: .visible
        ) {
            Button("Reset Sync") {
                do {
                    try resetSync?()
                    syncError = nil
                } catch {
                    syncError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All local history and iCloud data are kept. Pasta will download iCloud history again on the next sync.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch iCloudAvailable {
        case .some(true):
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .foregroundStyle(.green)
            }
        case .some(false):
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Unavailable")
                    .foregroundStyle(.red)
            }
        case .none:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
