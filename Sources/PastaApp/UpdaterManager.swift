import AppKit
import Foundation
import PastaCore
import Sparkle
import SwiftUI

/// Manages automatic updates using Sparkle framework
@MainActor
final class UpdaterManager: ObservableObject {
    /// Shared instance for app-wide access
    static let shared = UpdaterManager()

    let supportsSelfUpdate = SelfUpdateConfiguration.isConfigured(info: Bundle.main.infoDictionary ?? [:])

    /// The Sparkle updater controller
    private let updaterController: SPUStandardUpdaterController

    /// Whether automatic update checks are enabled
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard supportsSelfUpdate else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Whether the updater can check for updates (e.g., not already checking)
    @Published private(set) var canCheckForUpdates = false

    private init() {
        // Leave Sparkle stopped in local bundles that cannot receive updates.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: supportsSelfUpdate,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        automaticallyChecksForUpdates = supportsSelfUpdate && updaterController.updater.automaticallyChecksForUpdates
        guard supportsSelfUpdate else { return }

        // Observe canCheckForUpdates changes
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manually trigger an update check
    func checkForUpdates() {
        guard supportsSelfUpdate else {
            let alert = NSAlert()
            alert.messageText = "Updates unavailable"
            alert.informativeText = SelfUpdateConfiguration.unavailableMessage
            alert.runModal()
            return
        }
        guard canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    /// Access the underlying updater for SwiftUI integration
    var updater: SPUUpdater {
        updaterController.updater
    }
}
