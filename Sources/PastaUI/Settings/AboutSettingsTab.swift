import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - About Settings Tab

struct AboutSettingsTab: View {
    let checkForUpdates: (() -> Void)?
    let automaticallyChecksForUpdates: Binding<Bool>?
    
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
    
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
    
    private var commitRef: String? {
        Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String
    }
    
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(PastaTheme.accent)
                            .frame(width: 64, height: 64)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pasta")
                            .font(.title2.bold())
                        Text("Clipboard history for macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Built by Chris Mitchelmore")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text(buildNumber)
                        .foregroundStyle(.secondary)
                }
                if let commit = commitRef, !commit.isEmpty {
                    LabeledContent("Commit") {
                        Text(String(commit.prefix(7)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Version Info", systemImage: "tag")
            }
            
            Section {
                if let checkForUpdates {
                    HStack {
                        Text("Check for Updates")
                        Spacer()
                        Button("Check Now") {
                            checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                
                if let binding = automaticallyChecksForUpdates {
                    Toggle("Check automatically", isOn: binding)
                }
            } header: {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            
            Section {
                Text("Have a bug to report or feature to request?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/crmitchelmore/pasta/issues")!) {
                        Label("Report Issue", systemImage: "ladybug")
                    }
                    .buttonStyle(.bordered)
                    
                    Link(destination: URL(string: "https://github.com/crmitchelmore/pasta/issues/new")!) {
                        Label("Request Feature", systemImage: "lightbulb")
                    }
                    .buttonStyle(.bordered)
                    
                    Link(destination: URL(string: "https://github.com/crmitchelmore/pasta")!) {
                        Label("GitHub", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Label("Feedback & Support", systemImage: "bubble.left.and.bubble.right")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Built with:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    DependencyRow(name: "Sparkle", version: "2.6.0+", url: "https://sparkle-project.org", description: "Auto-update framework")
                    DependencyRow(name: "GRDB", version: "6.24+", url: "https://github.com/groue/GRDB.swift", description: "SQLite toolkit")
                }
            } header: {
                Label("Dependencies", systemImage: "shippingbox")
            }
            
            Section {
                Text("© 2024-2026 Chris Mitchelmore. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Link(destination: URL(string: "https://github.com/crmitchelmore/pasta/blob/main/LICENSE")!) {
                    Label("View License (MIT)", systemImage: "doc.plaintext")
                }
                .buttonStyle(.bordered)
            } header: {
                Label("Legal", systemImage: "doc.text")
            }
        }
        .formStyle(.grouped)
    }
}

struct DependencyRow: View {
    let name: String
    let version: String
    let url: String
    let description: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.bold())
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            Link(destination: URL(string: url)!) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
}
