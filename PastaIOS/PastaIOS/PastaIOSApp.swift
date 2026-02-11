import SwiftUI
import PastaCore
import PastaSync

@main
struct PastaIOSApp: App {
    @StateObject private var syncManager = SyncManager()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
                .environmentObject(appState)
                .task {
                    await appState.initialise(syncManager: syncManager)
                }
        }
    }
}
