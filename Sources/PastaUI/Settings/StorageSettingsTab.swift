import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Storage Settings Tab

struct StorageSettingsTab: View {
    @Binding var retentionDays: Int
    @Binding var maxEntries: Int

    @State private var storageSummary: String = "Calculating..."
    @State private var clearAllSummary: String? = nil
    @State private var isConfirmingClearAll: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Keep entries for", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }

                Picker("Maximum entries", selection: $maxEntries) {
                    Text("Unlimited").tag(0)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                }

                Text("Old entries are cleaned up automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Retention", systemImage: "clock.arrow.circlepath")
            }

            Section {
                LabeledContent("Database") {
                    Text(DatabaseManager.defaultDatabaseURL().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent("Images") {
                    Text(ImageStorageManager.defaultImagesDirectoryURL().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent("Usage") {
                    HStack {
                        Text(storageSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button {
                            refreshStorageSummary()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Label("Location", systemImage: "folder")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Clear All History…", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Spacer()
                }

                if let clearAllSummary {
                    Text(clearAllSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Label("Danger Zone", systemImage: "exclamationmark.triangle")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshStorageSummary()
        }
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all entries and stored images.")
        }
    }

    private func refreshStorageSummary() {
        do {
            let dbURL = DatabaseManager.defaultDatabaseURL()
            let dbSize = fileSizeBytes(at: dbURL)
            let imageStorage = try ImageStorageManager()
            let imageBytes = try imageStorage.totalStorageBytes()
            storageSummary = "DB: \(format(bytes: dbSize)) • Images: \(format(bytes: imageBytes))"
        } catch {
            storageSummary = "Unable to calculate"
        }
    }

    private func clearAllHistory() {
        do {
            let database = try DatabaseManager()
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            let count = try deleteService.deleteAll(includePinned: true)
            clearAllSummary = "Deleted \(count) entries"
            refreshStorageSummary()
        } catch {
            clearAllSummary = "Failed to clear history"
        }
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
