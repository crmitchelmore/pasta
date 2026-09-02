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
    @State private var isCalculatingStorage: Bool = false
    @State private var isClearingAll: Bool = false

    @State private var importResults: [ClipboardApp: ImportResult] = [:]
    @State private var isImporting: ClipboardApp? = nil
    @State private var importProgress: ImportProgress? = nil
    @State private var isExporting: Bool = false
    @State private var exportSummary: String? = nil
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        Form {
            retentionSection
            locationSection
            backupSection
            importSection
            dangerZoneSection
        }
        .formStyle(.grouped)
        .onAppear {
            refreshStorageSummary()
        }
        .alert("Import Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
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

    // MARK: Sections

    private var retentionSection: some View {
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
    }

    private var locationSection: some View {
        Section {
            LabeledContent("Database") {
                pathText(DatabaseManager.defaultDatabaseURL().path)
            }

            LabeledContent("Images") {
                pathText(ImageStorageManager.defaultImagesDirectoryURL().path)
            }

            LabeledContent("Usage") {
                HStack {
                    Text(storageSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isCalculatingStorage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            refreshStorageSummary()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Label("Location", systemImage: "folder")
        }
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var backupSection: some View {
        Section {
            HStack {
                Text("Export current history")
                Spacer()

                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Export My Data…") {
                        exportData()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isImporting != nil)
                }
            }

            if let exportSummary {
                Text(exportSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Creates a JSON backup of all clipboard entries, including metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Backup", systemImage: "square.and.arrow.up")
        }
    }

    private var importSection: some View {
        Section {
            ForEach(ClipboardApp.allCases) { app in
                ImportAppRow(
                    app: app,
                    result: importResults[app],
                    isImporting: isImporting == app,
                    isDisabled: isImporting != nil || isExporting,
                    progress: isImporting == app ? importProgress : nil,
                    onImport: { importFrom(app) }
                )
            }

            Text("Import clipboard history from other apps. Duplicate entries will be skipped automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Import from other apps", systemImage: "tray.and.arrow.down")
        }
    }

    private var dangerZoneSection: some View {
        Section {
            HStack {
                Spacer()
                if isClearingAll {
                    ProgressView()
                        .controlSize(.small)
                    Text("Clearing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Clear All History…", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                    .buttonStyle(.bordered)
                }
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

    // MARK: Storage

    /// Walks the whole images directory stat-ing every file, so it must not run
    /// on the main thread.
    private func refreshStorageSummary() {
        isCalculatingStorage = true

        DispatchQueue.global(qos: .userInitiated).async {
            let summary: String
            do {
                let dbSize = fileSizeBytes(at: DatabaseManager.defaultDatabaseURL())
                let imageStorage = try ImageStorageManager()
                let imageBytes = try imageStorage.totalStorageBytes()
                summary = "DB: \(format(bytes: dbSize)) • Images: \(format(bytes: imageBytes))"
            } catch {
                summary = "Unable to calculate"
            }

            DispatchQueue.main.async {
                storageSummary = summary
                isCalculatingStorage = false
            }
        }
    }

    /// Deletes every entry and every stored image — potentially tens of
    /// thousands of rows and files, so it runs off the main thread too.
    private func clearAllHistory() {
        isClearingAll = true

        DispatchQueue.global(qos: .userInitiated).async {
            let summary: String
            do {
                let database = try DatabaseManager()
                let imageStorage = try ImageStorageManager()
                let deleteService = DeleteService(database: database, imageStorage: imageStorage)
                let count = try deleteService.deleteAll(includePinned: true)
                summary = "Deleted \(count) entries"
            } catch {
                summary = "Failed to clear history"
            }

            DispatchQueue.main.async {
                clearAllSummary = summary
                isClearingAll = false
                refreshStorageSummary()
            }
        }
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Import / Export

    private func importFrom(_ app: ClipboardApp) {
        isImporting = app
        importProgress = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let database = try DatabaseManager()
                let imageStorage = try ImageStorageManager()
                let importService = ImportService(database: database, imageStorage: imageStorage)
                let result = try importService.importFrom(app) { progress in
                    DispatchQueue.main.async {
                        self.importProgress = progress
                    }
                }

                DispatchQueue.main.async {
                    importResults[app] = result
                    isImporting = nil
                    importProgress = nil

                    // Post notification to refresh main view
                    NotificationCenter.default.post(name: .entriesDidChange, object: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isImporting = nil
                    importProgress = nil
                }
            }
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private func exportData() {
        let panel = NSSavePanel()
        panel.title = "Export Pasta Data"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "pasta-export-\(Self.exportDateFormatter.string(from: Date())).json"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        isExporting = true
        exportSummary = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let database = try DatabaseManager()
                let imageStorage = try ImageStorageManager()
                let importService = ImportService(database: database, imageStorage: imageStorage)
                let result = try importService.exportAllEntries(to: destinationURL)

                DispatchQueue.main.async {
                    exportSummary = "Exported \(result.exported) entries to \(result.fileURL.lastPathComponent)"
                    isExporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    showError = true
                    isExporting = false
                }
            }
        }
    }
}

// MARK: - Import App Row

struct ImportAppRow: View {
    let app: ClipboardApp
    let result: ImportResult?
    let isImporting: Bool
    let isDisabled: Bool
    let progress: ImportProgress?
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: app.iconName)
                    .font(.title2)
                    .foregroundStyle(app.isAvailable ? .primary : .tertiary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.rawValue)
                        .font(.headline)
                        .foregroundStyle(app.isAvailable ? .primary : .secondary)

                    Text(app.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let result, !isImporting {
                        Text(result.summary)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                if isImporting {
                    if progress == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if app.isAvailable {
                    Button("Import") {
                        onImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDisabled)
                } else {
                    Text("Not installed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Progress bar section
            if isImporting, let progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction) {
                        HStack {
                            Text("Processing \(progress.current) of \(progress.total)")
                            Spacer()
                            Text("\(Int(progress.fraction * 100))%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)

                    HStack(spacing: 12) {
                        Label("\(progress.imported)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("\(progress.skipped)", systemImage: "arrow.right.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 4)
    }
}
