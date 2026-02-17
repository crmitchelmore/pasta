import SwiftUI
import PastaCore
import PastaSync

@main
struct PastaIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var syncManager = SyncManager(containerIdentifier: "iCloud.com.pasta.ios")
    @StateObject private var appState = AppState()

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
                    Task {
                        if appState.iCloudAvailable {
                            await appState.performSync(syncManager: syncManager)
                        }
                        await appState.captureCurrentClipboardIfNeeded(syncManager: syncManager)
                    }
                }
        }
    }
}
