import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Clipboard Settings Tab

struct ClipboardSettingsTab: View {
    private enum MultiCopyJoinSeparatorPreset: String, CaseIterable, Identifiable {
        case newline
        case tab
        case space
        case comma
        case commaSpace
        case custom

        var id: Self { self }

        var title: String {
            switch self {
            case .newline:
                return "New line"
            case .tab:
                return "Tab"
            case .space:
                return "Space"
            case .comma:
                return "Comma"
            case .commaSpace:
                return "Comma + space"
            case .custom:
                return "Custom"
            }
        }

        var separator: String? {
            switch self {
            case .newline:
                return "\n"
            case .tab:
                return "\t"
            case .space:
                return " "
            case .comma:
                return ","
            case .commaSpace:
                return ", "
            case .custom:
                return nil
            }
        }

        var helperText: String {
            switch self {
            case .newline:
                return "Each selected item is copied on its own line."
            case .tab:
                return "Selected items are separated by a tab character."
            case .space:
                return "Selected items are separated by a single space."
            case .comma:
                return "Selected items are separated by commas."
            case .commaSpace:
                return "Selected items are separated by commas and spaces."
            case .custom:
                return "Use any custom text to join copied values from the main list."
            }
        }

        static func matching(_ separator: String) -> Self {
            switch separator {
            case "\n":
                return .newline
            case "\t":
                return .tab
            case " ":
                return .space
            case ",":
                return .comma
            case ", ":
                return .commaSpace
            default:
                return .custom
            }
        }
    }

    @Binding var pauseMonitoring: Bool
    @Binding var storeImages: Bool
    @Binding var deduplicateEntries: Bool
    @Binding var multiCopyJoinSeparator: String
    @Binding var skipAPIKeys: Bool
    @Binding var respectTransientPasteboard: Bool
    @Binding var extractContent: Bool
    @Binding var playSounds: Bool
    @Binding var showNotifications: Bool
    @Binding var excludedAppsText: String
    @Binding var showPinnedSectionInQuickSearch: Bool

    @State private var multiCopyPreset: MultiCopyJoinSeparatorPreset = .newline

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
                Picker("Join copied selections with", selection: $multiCopyPreset) {
                    ForEach(MultiCopyJoinSeparatorPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if multiCopyPreset == .custom {
                    TextField("Custom separator", text: $multiCopyJoinSeparator)
                        .textFieldStyle(.roundedBorder)
                }

                Text(multiCopyPreset.helperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Multi-select Copy", systemImage: "doc.on.doc")
            }

            Section {
                Toggle("Extract emails, URLs, and more", isOn: $extractContent)
                Text("When enabled, emails, URLs, API keys, and other items found within copied text are also saved as separate entries for easy searching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Content Extraction", systemImage: "text.magnifyingglass")
            }

            Section {
                Toggle("Skip detected API keys", isOn: $skipAPIKeys)
                Text("When enabled, clipboard entries that look like API keys (OpenAI, GitHub, Stripe, AWS, etc.) won't be captured for security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Respect transient/concealed clipboards", isOn: $respectTransientPasteboard)
                Text("When enabled, items copied by password managers and other apps that mark the clipboard as transient or concealed (e.g. 1Password, Bitwarden) are ignored entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Security", systemImage: "lock.shield")
            }

            Section {
                Toggle("Show Pinned section at top of Quick Search", isOn: $showPinnedSectionInQuickSearch)
                Text("Groups pinned items under their own heading above recent history. Pinned items are always available via the Pinned filter chip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Quick Search", systemImage: "magnifyingglass")
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
        .onAppear {
            multiCopyPreset = MultiCopyJoinSeparatorPreset.matching(multiCopyJoinSeparator)
        }
        .onChange(of: multiCopyPreset) { _, newValue in
            guard let separator = newValue.separator else { return }
            if multiCopyJoinSeparator != separator {
                multiCopyJoinSeparator = separator
            }
        }
        .onChange(of: multiCopyJoinSeparator) { _, newValue in
            let matchingPreset = MultiCopyJoinSeparatorPreset.matching(newValue)
            if matchingPreset != multiCopyPreset {
                multiCopyPreset = matchingPreset
            }
        }
    }
}
