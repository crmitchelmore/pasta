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

                LabeledContent("Synced Entries") {
                    if syncManager.syncState == .syncing && syncManager.totalEntriesToSync > 0 {
                        Text("\(syncManager.syncedEntryCount) / \(syncManager.totalEntriesToSync)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("\(displayedSyncedCount)")
                            .foregroundStyle(.secondary)
                    }
                }
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
                    Spacer()
                    Button("Reset Sync…", role: .destructive) {
                        isResetting = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(resetSync == nil || isSyncing || syncManager.syncState == .syncing)
                    Spacer()
                }

                Text("Clears the sync token and forces a full re-sync from iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Danger Zone", systemImage: "exclamationmark.triangle")
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
        .confirmationDialog(
            "Reset sync data?",
            isPresented: $isResetting,
            titleVisibility: .visible
        ) {
            Button("Reset Sync", role: .destructive) {
                do {
                    try resetSync?()
                    syncError = nil
                } catch {
                    syncError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the sync token and forces a full re-download from iCloud on next sync.")
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
