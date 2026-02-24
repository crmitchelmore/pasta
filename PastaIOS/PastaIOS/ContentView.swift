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
                        }
                    }
            }
        }
        .sheet(isPresented: $appState.isShowingWhatsNew) {
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
    }
}

private struct WhatsNewView: View {
    @EnvironmentObject private var appState: AppState

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Latest"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("What’s New in \(version)")
                        .font(.headline)
                    Text("Pasta for iPhone now has clearer in-app guidance so people can understand the Mac+iCloud workflow quickly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Highlights") {
                    Label("Replay walkthrough from Settings", systemImage: "sparkles")
                    Label("Clearer onboarding on why Pasta exists", systemImage: "info.circle")
                    Label("Better explanation of search, copy, and sync flow", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("What’s New")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        appState.dismissWhatsNew()
                    }
                }
            }
        }
    }
}
