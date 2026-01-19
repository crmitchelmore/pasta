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
    }

    @AppStorage(Defaults.hotkeyKey) private var hotkeyKey: String = "c"
    @AppStorage(Defaults.hotkeyModifiers) private var hotkeyModifiersRaw: Int = Int(NSEvent.ModifierFlags([.control, .command]).rawValue)

    @AppStorage(Defaults.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(Defaults.maxEntries) private var maxEntries: Int = 0 // 0 = unlimited
    @AppStorage(Defaults.excludedApps) private var excludedAppsText: String = ""

    @State private var storageSummary: String = "—"
    @State private var clearAllSummary: String? = nil

    @State private var isConfirmingClearAll: Bool = false

    public init() {}

    public var body: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Key")
                    Spacer()
                    Picker("Key", selection: $hotkeyKey) {
                        ForEach(Self.supportedKeys, id: \.self) { key in
                            Text(key.uppercased()).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                modifiersRow

                Text("Changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .help("Implemented in a later PRD item")
            }

            Section("Storage") {
                LabeledContent("Database") {
                    Text(DatabaseManager.defaultDatabaseURL().path)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                LabeledContent("Images") {
                    Text(ImageStorageManager.defaultImagesDirectoryURL().path)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                LabeledContent("Usage") {
                    Text(storageSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Refresh") {
                        refreshStorageSummary()
                    }

                    Spacer()

                    Button("Clear all history…", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                }

                if let clearAllSummary {
                    Text(clearAllSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Limits") {
                Stepper(value: $maxEntries, in: 0...50_000, step: 100) {
                    if maxEntries == 0 {
                        Text("Max entries: Unlimited")
                    } else {
                        Text("Max entries: \(maxEntries)")
                    }
                }
                .help("Enforcement implemented in a later PRD item")
            }

            Section("Excluded apps") {
                TextEditor(text: $excludedAppsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)

                Text("One bundle id per line (e.g. com.apple.Terminal).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            refreshStorageSummary()
        }
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) {
                clearAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all entries and any stored images.")
        }
    }

    private var modifiersRow: some View {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiersRaw))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Modifiers")

            HStack(spacing: 12) {
                Toggle("⌃", isOn: binding(for: .control, in: flags))
                Toggle("⌥", isOn: binding(for: .option, in: flags))
                Toggle("⇧", isOn: binding(for: .shift, in: flags))
                Toggle("⌘", isOn: binding(for: .command, in: flags))
            }
            .toggleStyle(.button)
        }
    }

    private func binding(for flag: NSEvent.ModifierFlags, in flags: NSEvent.ModifierFlags) -> Binding<Bool> {
        Binding(
            get: { flags.contains(flag) },
            set: { newValue in
                var updated = NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiersRaw))
                if newValue {
                    updated.insert(flag)
                } else {
                    updated.remove(flag)
                }
                hotkeyModifiersRaw = Int(updated.rawValue)
            }
        )
    }

    private func refreshStorageSummary() {
        do {
            let dbURL = DatabaseManager.defaultDatabaseURL()
            let dbSize = Self.fileSizeBytes(at: dbURL)

            let imageStorage = try ImageStorageManager()
            let imageBytes = try imageStorage.totalStorageBytes()

            storageSummary = "DB \(Self.format(bytes: dbSize)), Images \(Self.format(bytes: imageBytes))"
        } catch {
            storageSummary = "Unavailable"
        }
    }

    private func clearAllHistory() {
        do {
            let database = try (DatabaseManager())
            let imageStorage = try ImageStorageManager()
            let deleteService = DeleteService(database: database, imageStorage: imageStorage)
            let count = try deleteService.deleteAll()
            clearAllSummary = "Deleted \(count) entries"
            refreshStorageSummary()
        } catch {
            clearAllSummary = "Clear failed"
        }
    }

    private static var supportedKeys: [String] {
        ["c", "v", "p", "space"]
    }

    private static func fileSizeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
