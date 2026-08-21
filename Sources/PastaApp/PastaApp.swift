import AppKit
import Sentry
import SwiftUI
import os.log

import PastaCore
import PastaDetectors
import PastaUI

// (PastaTheme lives in PastaUI)

extension Notification.Name {
    static let openSettings = Notification.Name("pasta.openSettings")
    static let openOnboarding = Notification.Name("pasta.openOnboarding")
    static let applyContentTypeFilter = Notification.Name("pasta.applyContentTypeFilter")
}

/// Userinfo key for `applyContentTypeFilter` carrying an optional `ContentType`.
/// `nil` means clear the filter (show all).
enum ApplyContentTypeFilterKey {
    static let contentType = "contentType"
}

@main
struct PastaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Initialize Sentry as early as possible
        SentryManager.start()
    }

    var body: some Scene {
        Settings {
            let database = BackgroundService.shared.database
            SettingsView(
                syncManager: BackgroundService.shared.syncManager,
                unsyncedEntries: { (try? database.fetchUnsynced()) ?? [] },
                markSynced: { ids in
                    try? BackgroundService.shared.database.markSynced(ids: ids)
                },
                syncedCount: {
                    (try? BackgroundService.shared.database.syncedCount()) ?? 0
                },
                syncNow: {
                    await BackgroundService.shared.syncNow()
                },
                openWalkthrough: {
                    NotificationCenter.default.post(name: .openOnboarding, object: nil)
                },
                checkForUpdates: { UpdaterManager.shared.checkForUpdates() },
                automaticallyChecksForUpdates: Binding(
                    get: { UpdaterManager.shared.automaticallyChecksForUpdates },
                    set: { UpdaterManager.shared.automaticallyChecksForUpdates = $0 }
                )
            )
            .frame(minWidth: 450, minHeight: 400)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdaterManager.shared.checkForUpdates()
                }
            }
        }
    }
}
