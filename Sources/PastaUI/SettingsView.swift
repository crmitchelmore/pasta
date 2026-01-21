import AppKit
import PastaCore
import SwiftUI

public struct SettingsView: View {
    private enum Defaults {
        static let hotkeyKey = "pasta.hotkey.key"
        static let hotkeyModifiers = "pasta.hotkey.modifiers"
        static let launchAtLogin = "pasta.launchAtLogin"
        static let maxEntries = "pasta.maxEntries"
        static let excludedApps = "pasta.excludedApps"
        static let appMode = "pasta.appMode"
        static let retentionDays = "pasta.retentionDays"
        static let pauseMonitoring = "pasta.pauseMonitoring"
        static let playSounds = "pasta.playSounds"
        static let showNotifications = "pasta.showNotifications"
        static let storeImages = "pasta.storeImages"
        static let deduplicateEntries = "pasta.deduplicateEntries"
    }

    @AppStorage(Defaults.hotkeyKey) private var hotkeyKey: String = "c"
    @AppStorage(Defaults.hotkeyModifiers) private var hotkeyModifiersRaw: Int = Int(NSEvent.ModifierFlags([.control, .command]).rawValue)
    @AppStorage(Defaults.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(Defaults.maxEntries) private var maxEntries: Int = 0
    @AppStorage(Defaults.excludedApps) private var excludedAppsText: String = ""
    @AppStorage(Defaults.appMode) private var appMode: String = "both"
    @AppStorage(Defaults.retentionDays) private var retentionDays: Int = 0
    @AppStorage(Defaults.pauseMonitoring) private var pauseMonitoring: Bool = false
    @AppStorage(Defaults.playSounds) private var playSounds: Bool = false
    @AppStorage(Defaults.showNotifications) private var showNotifications: Bool = false
    @AppStorage(Defaults.storeImages) private var storeImages: Bool = true
    @AppStorage(Defaults.deduplicateEntries) private var deduplicateEntries: Bool = true

    @State private var selectedTab: SettingsTab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(
                hotkeyKey: $hotkeyKey,
                hotkeyModifiersRaw: $hotkeyModifiersRaw,
                launchAtLogin: $launchAtLogin,
                appMode: $appMode
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(SettingsTab.general)

            ClipboardSettingsTab(
                pauseMonitoring: $pauseMonitoring,
                storeImages: $storeImages,
                deduplicateEntries: $deduplicateEntries,
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
        }
        .frame(width: 500, height: 420)
    }

    private enum SettingsTab: Hashable {
        case general, clipboard, storage
    }
}

// MARK: - General Settings Tab

private struct GeneralSettingsTab: View {
    @Binding var hotkeyKey: String
    @Binding var hotkeyModifiersRaw: Int
    @Binding var launchAtLogin: Bool
    @Binding var appMode: String

    var body: some View {
        Form {
            Section {
                HotkeyRecorderRow(
                    hotkeyKey: $hotkeyKey,
                    hotkeyModifiersRaw: $hotkeyModifiersRaw
                )
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
                Label("Appearance", systemImage: "macwindow")
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

// MARK: - Hotkey Recorder

private struct HotkeyRecorderRow: View {
    @Binding var hotkeyKey: String
    @Binding var hotkeyModifiersRaw: Int

    @State private var isRecording = false
    @State private var pendingKey: String? = nil
    @State private var pendingModifiers: Int? = nil

    private var displayString: String {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiersRaw))
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(hotkeyKey.uppercased())
        return parts.joined()
    }

    private var pendingDisplayString: String {
        guard let key = pendingKey, let mods = pendingModifiers else { return "" }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(mods))
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    var body: some View {
        HStack {
            Text("Open Pasta")
            
            Spacer()

            if isRecording {
                HStack(spacing: 8) {
                    HotkeyRecorderField(
                        pendingKey: $pendingKey,
                        pendingModifiers: $pendingModifiers
                    )
                    .frame(width: 120, height: 28)
                    
                    if pendingKey != nil {
                        Button("Save") {
                            if let key = pendingKey, let mods = pendingModifiers {
                                hotkeyKey = key
                                hotkeyModifiersRaw = mods
                            }
                            isRecording = false
                            pendingKey = nil
                            pendingModifiers = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    
                    Button("Cancel") {
                        isRecording = false
                        pendingKey = nil
                        pendingModifiers = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button {
                    isRecording = true
                    pendingKey = nil
                    pendingModifiers = nil
                } label: {
                    Text(displayString)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// NSViewRepresentable for capturing key events
private struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var pendingKey: String?
    @Binding var pendingModifiers: Int?

    func makeNSView(context: Context) -> HotkeyTextField {
        let field = HotkeyTextField()
        field.onKeyRecorded = { key, modifiers in
            pendingKey = key
            pendingModifiers = modifiers
        }
        return field
    }

    func updateNSView(_ nsView: HotkeyTextField, context: Context) {
        if let key = pendingKey, let mods = pendingModifiers {
            nsView.updateDisplay(key: key, modifiers: mods)
        }
    }
}

private class HotkeyTextField: NSTextField {
    var onKeyRecorded: ((String, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        placeholderString = "Press keys..."
        stringValue = ""
        
        // Make it focusable
        focusRingType = .exterior
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        stringValue = ""
        placeholderString = "Press keys..."
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              !characters.isEmpty else { return }

        let key = characters
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])

        // Require at least one modifier
        guard !modifiers.isEmpty else {
            placeholderString = "Add ⌘, ⌃, ⌥, or ⇧"
            return
        }

        updateDisplay(key: key, modifiers: Int(modifiers.rawValue))
        onKeyRecorded?(key, Int(modifiers.rawValue))
    }

    func updateDisplay(key: String, modifiers: Int) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        stringValue = parts.joined()
    }
}
