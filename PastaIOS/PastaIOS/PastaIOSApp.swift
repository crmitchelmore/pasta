import SwiftUI
import PastaCore
import PastaSync

@main
struct PastaIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var syncManager = SyncManager(containerIdentifier: "iCloud.com.pasta.ios")
    @StateObject private var appState = AppState()
    @State private var foregroundActivationTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
                .environmentObject(appState)
                .task {
                    await appState.initialise(syncManager: syncManager)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    foregroundActivationTask?.cancel()
                    foregroundActivationTask = Task {
                        await appState.handleAppDidBecomeActive(syncManager: syncManager)
                    }
                }
        }
    }
}
