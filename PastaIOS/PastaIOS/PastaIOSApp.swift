import SwiftUI
import CloudKit
import PastaCore
import PastaSync

@main
struct PastaIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var syncManager = Self.makeSyncManager()
    @StateObject private var appState = AppState()
    @State private var foregroundActivationTask: Task<Void, Never>?

    private static func makeSyncManager() -> SyncManager {
        let manager = SyncManager(
            containerIdentifier: "iCloud.com.pasta.ios",
            syncEnabled: true,
            cloudKitProvisioned: Self.cloudKitProvisioned
        )
        if UITestConfiguration.isActive {
            // Exercise the app → SwiftPM boundary without constructing a
            // container. Unlike assert, this probe also runs in Release tests.
            precondition(SyncManager(cloudKitProvisioned: true).cloudKitAccessAllowed,
                         "PastaSync did not accept the provisioned iOS host")
            precondition(!SyncManager().cloudKitAccessAllowed,
                         "PastaSync must deny an unprovisioned iOS host")
            precondition(!SyncManager(syncEnabled: false, cloudKitProvisioned: true).cloudKitAccessAllowed,
                         "Provisioning must not override disabled sync")
            precondition(manager.cloudKitAccessAllowed == Self.cloudKitProvisioned,
                         "CloudKit provisioning approval did not reach PastaSync")
        }
        return manager
    }

    // App target conditions do not propagate into the PastaSync Swift package.
    // Release signing gates validate this host's entitlement before publication.
    private static var cloudKitProvisioned: Bool {
        #if PASTA_IOS_CLOUDKIT_PROVISIONED
        return true
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncManager)
                .environmentObject(appState)
                .task {
                    await appState.initialise(syncManager: syncManager)
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    Task { await appState.performSync(syncManager: syncManager) }
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
