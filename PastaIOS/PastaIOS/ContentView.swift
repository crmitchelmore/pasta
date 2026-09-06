import SwiftUI
import PastaCore
import PastaSync

struct ContentView: View {
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if appState.isLoading {
                LoadingView()
            } else {
                MainTabView()
            }
        }
        .sheet(isPresented: $appState.isShowingOnboarding) {
            NavigationStack {
                OnboardingView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                appState.dismissOnboarding()
                            }
                            .accessibilityIdentifier("onboarding.toolbarDone")
                        }
                    }
            }
        }
        .sheet(isPresented: $appState.isShowingWhatsNew, onDismiss: appState.dismissWhatsNew) {
            WhatsNewView()
        }
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Syncing clipboard history…")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("loading.view")
    }
}

private struct WhatsNewView: View {
    @EnvironmentObject private var appState: AppState
    private let catalog = ReleaseNotesCatalog.bundled
    private var version: String { AppState.currentAppVersion() }
    private var build: String { AppState.currentAppBuild() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Version \(version) (\(build))")
                        .font(.headline)
                        .accessibilityIdentifier("whatsNew.installedVersion")
                    if let entry = catalog.entry(version: version, build: build) {
                        ReleaseNoteContent(entry: entry)
                    } else {
                        Text("Release notes for this installed build are not bundled. Earlier notes are available below.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("whatsNew.unavailable")
                    }
                } header: {
                    Text("Installed version")
                }
                let history = catalog.history(version: version, build: build)
                if !history.isEmpty {
                    Section("Earlier versions") {
                        ForEach(history) { entry in
                            NavigationLink {
                                List { ReleaseNoteContent(entry: entry) }
                                    .navigationTitle(entry.title)
                                    .accessibilityIdentifier("whatsNew.detail")
                            } label: {
                                Text(entry.title)
                            }
                            .accessibilityIdentifier("whatsNew.history.\(entry.id)")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("whatsNew.list")
            .navigationTitle("What’s New")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { appState.dismissWhatsNew() }
                        .accessibilityIdentifier("whatsNew.done")
                }
            }
        }
    }
}

private struct ReleaseNoteContent: View {
    let entry: ReleaseNoteEntry

    var body: some View {
        Text(.init(entry.summary))
            .font(.headline)
            .accessibilityIdentifier("whatsNew.summary")
        if !entry.date.isEmpty {
            Text(entry.date).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
            Text(.init(change))
                .textSelection(.enabled)
        }
        if let url = URL(string: entry.source), url.scheme == "https", url.host == "github.com" {
            Link("Full changelog", destination: url)
        }
    }
}
