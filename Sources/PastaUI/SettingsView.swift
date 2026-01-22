import AppKit
import KeyboardShortcuts
import PastaCore
import SwiftUI

public struct SettingsView: View {
    private enum Defaults {
        static let launchAtLogin = "pasta.launchAtLogin"
        static let maxEntries = "pasta.maxEntries"
        static let excludedApps = "pasta.excludedApps"
        static let appMode = "pasta.appMode"
        static let appearance = "pasta.appearance"
        static let retentionDays = "pasta.retentionDays"
        static let pauseMonitoring = "pasta.pauseMonitoring"
        static let playSounds = "pasta.playSounds"
        static let showNotifications = "pasta.showNotifications"
        static let storeImages = "pasta.storeImages"
        static let deduplicateEntries = "pasta.deduplicateEntries"
        static let skipAPIKeys = "pasta.skipAPIKeys"
    }

    @AppStorage(Defaults.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(Defaults.maxEntries) private var maxEntries: Int = 0
    @AppStorage(Defaults.excludedApps) private var excludedAppsText: String = ""
    @AppStorage(Defaults.appMode) private var appMode: String = "both"
    @AppStorage(Defaults.appearance) private var appearance: String = "system"
    @AppStorage(Defaults.retentionDays) private var retentionDays: Int = 0
    @AppStorage(Defaults.pauseMonitoring) private var pauseMonitoring: Bool = false
    @AppStorage(Defaults.playSounds) private var playSounds: Bool = false
    @AppStorage(Defaults.showNotifications) private var showNotifications: Bool = false
    @AppStorage(Defaults.storeImages) private var storeImages: Bool = true
    @AppStorage(Defaults.deduplicateEntries) private var deduplicateEntries: Bool = true
    @AppStorage(Defaults.skipAPIKeys) private var skipAPIKeys: Bool = false

    @State private var selectedTab: SettingsTab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(
                launchAtLogin: $launchAtLogin,
                appMode: $appMode,
                appearance: $appearance
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(SettingsTab.general)

            ClipboardSettingsTab(
                pauseMonitoring: $pauseMonitoring,
                storeImages: $storeImages,
                deduplicateEntries: $deduplicateEntries,
                skipAPIKeys: $skipAPIKeys,
                playSounds: $playSounds,
                showNotifications: $showNotifications,
                excludedAppsText: $excludedAppsText
            )
            .tabItem {
                Label("Clipboard", systemImage: "doc.on.clipboard")
            }
            .tag(SettingsTab.clipboard)

            StorageSettingsTab(
                retentionDays: $retentionDays,
                maxEntries: $maxEntries
            )
            .tabItem {
                Label("Storage", systemImage: "internaldrive")
            }
            .tag(SettingsTab.storage)
            
            ImportSettingsTab()
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .tag(SettingsTab.import)
        }
        .frame(minWidth: 520, minHeight: 480)
        .frame(idealWidth: 600, idealHeight: 550)
        .withAppearance()
        .tint(PastaTheme.accent)
    }

    private enum SettingsTab: Hashable {
        case general, clipboard, storage, `import`
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsTab: View {
    @Binding var launchAtLogin: Bool
    @Binding var appMode: String
    @Binding var appearance: String

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Open Pasta")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .openPasta)
                }
            } header: {
                Label("Keyboard Shortcut", systemImage: "keyboard")
            }

            Section {
                Toggle("Launch Pasta at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            let manager = LaunchAtLoginManager()
                            launchAtLogin = try manager.setEnabled(newValue)
                        } catch {
                            launchAtLogin = LaunchAtLoginManager().isEnabled
                        }
                    }
            } header: {
                Label("Startup", systemImage: "power")
            }

            Section {
                Picker("Show Pasta in", selection: $appMode) {
                    Text("Menu bar only").tag("menuBar")
                    Text("Dock only").tag("dock")
                    Text("Menu bar and Dock").tag("both")
                }
                .pickerStyle(.radioGroup)

                Text("Dock mode shows Pasta in ⌘⇥ app switcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("App Icon", systemImage: "macwindow")
            }
            
            Section {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.radioGroup)
                
                Text("Choose how Pasta appears on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager().isEnabled
        }
    }
}

// MARK: - Clipboard Settings Tab

private struct ClipboardSettingsTab: View {
    @Binding var pauseMonitoring: Bool
    @Binding var storeImages: Bool
    @Binding var deduplicateEntries: Bool
    @Binding var skipAPIKeys: Bool
    @Binding var playSounds: Bool
    @Binding var showNotifications: Bool
    @Binding var excludedAppsText: String

    var body: some View {
        Form {
            Section {
                Toggle("Pause clipboard monitoring", isOn: $pauseMonitoring)
                Toggle("Store copied images", isOn: $storeImages)
                Toggle("Deduplicate identical entries", isOn: $deduplicateEntries)
            } header: {
                Label("Capture", systemImage: "rectangle.and.paperclip")
            }

            Section {
                Toggle("Skip detected API keys", isOn: $skipAPIKeys)
                Text("When enabled, clipboard entries that look like API keys (OpenAI, GitHub, Stripe, AWS, etc.) won't be captured for security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Security", systemImage: "lock.shield")
            }

            Section {
                Toggle("Play sound on capture", isOn: $playSounds)
                Toggle("Show notification on capture", isOn: $showNotifications)
            } header: {
                Label("Feedback", systemImage: "bell")
            }

            Section {
                TextEditor(text: $excludedAppsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("One bundle ID per line (e.g. com.apple.Terminal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Excluded Apps", systemImage: "xmark.app")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage Settings Tab

private struct StorageSettingsTab: View {
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
            let count = try deleteService.deleteAll()
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

// MARK: - Import Settings Tab

private struct ImportSettingsTab: View {
    private enum ImportDefaults {
        static func lastImportKey(for app: ClipboardApp) -> String {
            "pasta.import.lastDate.\(app.rawValue)"
        }
    }
    
    @State private var importResults: [ClipboardApp: ImportResult] = [:]
    @State private var isImporting: ClipboardApp? = nil
    @State private var importProgress: ImportProgress? = nil
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showReimportConfirmation: Bool = false
    @State private var pendingImportApp: ClipboardApp? = nil
    
    var body: some View {
        Form {
            Section {
                Text("Import clipboard history from other apps. Duplicate entries will be skipped automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                ForEach(ClipboardApp.allCases) { app in
                    ImportAppRow(
                        app: app,
                        result: importResults[app],
                        isImporting: isImporting == app,
                        progress: isImporting == app ? importProgress : nil,
                        lastImportDate: lastImportDate(for: app),
                        onImport: { handleImportRequest(app) }
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
        .confirmationDialog(
            "Reimport from \(pendingImportApp?.rawValue ?? "")?",
            isPresented: $showReimportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reimport") {
                if let app = pendingImportApp {
                    importFrom(app)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingImportApp = nil
            }
        } message: {
            if let app = pendingImportApp, let lastDate = lastImportDate(for: app) {
                Text("You last imported from \(app.rawValue) on \(lastDate.formatted(date: .abbreviated, time: .shortened)). Duplicates will be skipped.")
            } else {
                Text("This will import all clipboard history from the selected app. Duplicates will be skipped.")
            }
        }
    }
    
    private func lastImportDate(for app: ClipboardApp) -> Date? {
        UserDefaults.standard.object(forKey: ImportDefaults.lastImportKey(for: app)) as? Date
    }
    
    private func setLastImportDate(for app: ClipboardApp) {
        UserDefaults.standard.set(Date(), forKey: ImportDefaults.lastImportKey(for: app))
    }
    
    private func handleImportRequest(_ app: ClipboardApp) {
        if lastImportDate(for: app) != nil {
            // Show confirmation for reimport
            pendingImportApp = app
            showReimportConfirmation = true
        } else {
            // First time import, proceed directly
            importFrom(app)
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
                    setLastImportDate(for: app)
                    
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
}

private struct ImportAppRow: View {
    let app: ClipboardApp
    let result: ImportResult?
    let isImporting: Bool
    let progress: ImportProgress?
    let lastImportDate: Date?
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
                    } else if let lastImportDate, !isImporting {
                        Text("Last imported: \(lastImportDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
                
                if isImporting {
                    if progress == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if app.isAvailable {
                    Button(lastImportDate != nil ? "Reimport" : "Import") {
                        onImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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

// MARK: - Notification Name Extension

extension Notification.Name {
    static let entriesDidChange = Notification.Name("pasta.entriesDidChange")
}
