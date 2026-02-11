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
