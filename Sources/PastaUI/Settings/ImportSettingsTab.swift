import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import Settings Tab

struct ImportSettingsTab: View {
    @State private var importResults: [ClipboardApp: ImportResult] = [:]
    @State private var isImporting: ClipboardApp? = nil
    @State private var importProgress: ImportProgress? = nil
    @State private var isExporting: Bool = false
    @State private var exportSummary: String? = nil
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        Form {
            Section {
                Text("Import clipboard history from other apps. Duplicate entries will be skipped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
            } header: {
                Label("Available Sources", systemImage: "tray.and.arrow.down")
            }
        }
        .formStyle(.grouped)
        .alert("Import Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
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
