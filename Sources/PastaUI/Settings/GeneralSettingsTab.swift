import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @Binding var launchAtLogin: Bool
    @Binding var appMode: String
    @Binding var appearance: String
    let onReplayWalkthrough: (() -> Void)?

    @AppStorage("pasta.crashReportingEnabled") private var crashReportingEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Open Pasta")
                    Spacer()
                    ShortcutRecorderView(
                        hotKey: PastaHotKey.load()
                    )
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

            Section {
                HStack {
                    Text("Feature walkthrough")
                    Spacer()
                    Button("Replay Walkthrough…") {
                        onReplayWalkthrough?()
                    }
                    .buttonStyle(.bordered)
                    .disabled(onReplayWalkthrough == nil)
                }
                Text("Reopen the onboarding tour for commands, preview actions, and search/filter tips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Help", systemImage: "sparkles")
            }

            Section {
                Toggle("Send anonymous crash reports", isOn: $crashReportingEnabled)
                Text("Off by default. Sends crash reports and minimal performance traces to Sentry — never clipboard contents. Takes effect after restarting Pasta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Diagnostics", systemImage: "ladybug")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLoginManager().isEnabled
        }
    }
}
