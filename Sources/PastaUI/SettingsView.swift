import AppKit
import PastaCore
import PastaDetectors
import PastaSync
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    private enum Defaults {
        static let launchAtLogin = "pasta.launchAtLogin"
        static let maxEntries = "pasta.maxEntries"
        static let excludedApps = "pasta.excludedApps"
        static let appMode = "pasta.appMode"
        static let appearance = "pasta.appearance"
        static let retentionDays = "pasta.retentionDays"
        static let pauseMonitoring = "pasta.pauseMonitoring"
        static let playSounds = "pasta.playSounds"
        static let showNotifications = "pasta.showNotifications"
        static let storeImages = "pasta.storeImages"
        static let deduplicateEntries = "pasta.deduplicateEntries"
        static let multiCopyJoinSeparator = "pasta.multiCopyJoinSeparator"
        static let skipAPIKeys = "pasta.skipAPIKeys"
        static let respectTransientPasteboard = "pasta.respectTransientPasteboard"
        static let extractContent = "pasta.extractContent"
        static let showPinnedSectionInQuickSearch = "pasta.showPinnedSectionInQuickSearch"
    }

    private enum Layout {
        static let settingsWidth: CGFloat = 680
        static let settingsHeight: CGFloat = 500
    }

    @AppStorage(Defaults.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(Defaults.maxEntries) private var maxEntries: Int = 0
    @AppStorage(Defaults.excludedApps) private var excludedAppsText: String = ""
    @AppStorage(Defaults.appMode) private var appMode: String = "both"
    @AppStorage(Defaults.appearance) private var appearance: String = "system"
    @AppStorage(Defaults.retentionDays) private var retentionDays: Int = 0
    @AppStorage(Defaults.pauseMonitoring) private var pauseMonitoring: Bool = false
    @AppStorage(Defaults.playSounds) private var playSounds: Bool = false
    @AppStorage(Defaults.showNotifications) private var showNotifications: Bool = false
    @AppStorage(Defaults.storeImages) private var storeImages: Bool = true
    @AppStorage(Defaults.deduplicateEntries) private var deduplicateEntries: Bool = true
    @AppStorage(Defaults.multiCopyJoinSeparator) private var multiCopyJoinSeparator: String = "\n"
    @AppStorage(Defaults.skipAPIKeys) private var skipAPIKeys: Bool = false
    @AppStorage(Defaults.respectTransientPasteboard) private var respectTransientPasteboard: Bool = true
    @AppStorage(Defaults.extractContent) private var extractContent: Bool = true
    @AppStorage(Defaults.showPinnedSectionInQuickSearch) private var showPinnedSectionInQuickSearch: Bool = false

    @State private var selectedTab: SettingsTab = .general
    
    private let checkForUpdates: (() -> Void)?
    private let automaticallyChecksForUpdates: Binding<Bool>?
    private let openWalkthrough: (() -> Void)?
    private let syncManager: SyncManager?
    private let syncNow: (@MainActor () async throws -> Void)?
    private let syncedCount: (() -> Int)?

    public init(
        syncManager: SyncManager? = nil,
        syncNow: (@MainActor () async throws -> Void)? = nil,
        syncedCount: (() -> Int)? = nil,
        openWalkthrough: (() -> Void)? = nil,
        checkForUpdates: (() -> Void)? = nil,
        automaticallyChecksForUpdates: Binding<Bool>? = nil
    ) {
        self.syncManager = syncManager
        self.syncNow = syncNow
        self.syncedCount = syncedCount
        self.openWalkthrough = openWalkthrough
        self.checkForUpdates = checkForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(
                launchAtLogin: $launchAtLogin,
                appMode: $appMode,
                appearance: $appearance,
                onReplayWalkthrough: openWalkthrough
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .tag(SettingsTab.general)

            ClipboardSettingsTab(
                pauseMonitoring: $pauseMonitoring,
                storeImages: $storeImages,
                deduplicateEntries: $deduplicateEntries,
                multiCopyJoinSeparator: $multiCopyJoinSeparator,
                skipAPIKeys: $skipAPIKeys,
                respectTransientPasteboard: $respectTransientPasteboard,
                extractContent: $extractContent,
                playSounds: $playSounds,
                showNotifications: $showNotifications,
                excludedAppsText: $excludedAppsText,
                showPinnedSectionInQuickSearch: $showPinnedSectionInQuickSearch
            )
            .tabItem {
                Label("Clipboard", systemImage: "doc.on.clipboard")
            }
            .tag(SettingsTab.clipboard)

            DetectionRulesSettingsTab()
                .tabItem {
                    Label("Detection", systemImage: "line.3.horizontal.decrease.circle")
                }
                .tag(SettingsTab.detection)

            StorageSettingsTab(
                retentionDays: $retentionDays,
                maxEntries: $maxEntries
            )
            .tabItem {
                Label("Storage", systemImage: "internaldrive")
            }
            .tag(SettingsTab.storage)
            
            if let syncManager {
                iCloudSettingsTab(
                    syncManager: syncManager,
                    syncNow: syncNow,
                    syncedCount: syncedCount ?? { 0 }
                )
                    .tabItem {
                        Label("iCloud", systemImage: "icloud")
                    }
                    .tag(SettingsTab.iCloud)
            }
            
            SnippetsSettingsTab()
            .tabItem {
                Label("Snippets", systemImage: "text.badge.plus")
            }
            .tag(SettingsTab.snippets)
            
            AboutSettingsTab(
                checkForUpdates: checkForUpdates,
                automaticallyChecksForUpdates: automaticallyChecksForUpdates
            )
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
            .tag(SettingsTab.about)
        }
        // Wide enough for all seven tab items; keep in sync with the tab count so
        // the macOS tab bar never overflows.
        .frame(width: Layout.settingsWidth, height: Layout.settingsHeight)
        .padding(.top, 8)
        .withAppearance()
        .tint(PastaTheme.accent)
    }

    private enum SettingsTab: Hashable {
        case general, clipboard, detection, storage, iCloud, snippets, about
    }
}

// MARK: - Notification Name Extension

extension Notification.Name {
    static let entriesDidChange = Notification.Name("pasta.entriesDidChange")
}
