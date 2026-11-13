import AppIntents
import Foundation
import PastaCore
import PastaDetectors
#if canImport(UIKit)
import UIKit
#endif

// Review rule ITMS-90626: no platform, device or assistant brand names may
// appear in intent titles, descriptions, dialogs or phrases. A SwiftPM test
// (`ShortcutsMetadataTests`) scans this file for them.

/// One database handle shared by every action, opened on first use.
enum ShortcutsHistoryStore {
    static let historyChanged = Notification.Name("PastaShortcutsHistoryChanged")

    private static let lock = NSLock()
    private nonisolated(unsafe) static var database: DatabaseManager?

    static func history() throws -> ClipboardHistoryShortcuts {
        lock.lock()
        defer { lock.unlock() }
        if let database { return ClipboardHistoryShortcuts(database: database) }
        let opened = try DatabaseManager(databaseURL: AppState.databaseURL())
        database = opened
        return ClipboardHistoryShortcuts(database: opened)
    }
}

enum ClipKind: String, AppEnum {
    case text, url, email, phoneNumber, code, apiKey, envVar, uuid, jwt, ipAddress, color

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Clip Type"
    static let caseDisplayRepresentations: [ClipKind: DisplayRepresentation] = [
        .text: "Text", .url: "Link", .email: "Email Address", .phoneNumber: "Phone Number",
        .code: "Code", .apiKey: "API Key", .envVar: "Environment Variable", .uuid: "UUID",
        .jwt: "JWT", .ipAddress: "IP Address", .color: "Colour",
    ]

    var contentType: ContentType { ContentType(rawValue: rawValue) ?? .text }
}

struct SaveToPastaIntent: AppIntent {
    static let title: LocalizedStringResource = "Save to Pasta"
    static let description = IntentDescription(
        "Saves text to your Pasta history and detects what it is, such as a link, email address or API key. Detected secrets stay on this device unless you allow them to sync."
    )

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Save \(\.$text) to Pasta") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let syncSecrets = UserDefaults.standard.bool(forKey: AppState.syncDetectedSecretsKey)
        guard let entry = try ShortcutsHistoryStore.history().save(text, syncSensitiveContent: syncSecrets) else {
            throw ShortcutsError.emptyText
        }
        NotificationCenter.default.post(name: ShortcutsHistoryStore.historyChanged, object: nil)
        let kind = entry.contentType.displayName
        let dialog: IntentDialog = entry.allowsCloudUpload
            ? "Saved to Pasta as \(kind)."
            : "Saved to Pasta as \(kind). It stays on this device."
        return .result(value: kind, dialog: dialog)
    }
}

struct CopyLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Clip"
    static let description = IntentDescription(
        "Copies the most recent clip from your Pasta history, optionally the latest of one type such as a link or code."
    )

    @Parameter(title: "Type")
    var kind: ClipKind?

    static var parameterSummary: some ParameterSummary { Summary("Copy latest \(\.$kind) clip") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let entry = try ShortcutsHistoryStore.history().latest(contentType: kind?.contentType) else {
            throw ShortcutsError.noMatchingClip
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = entry.content
        #endif
        return .result(value: entry.content, dialog: "Copied your latest \(entry.contentType.displayName) clip.")
    }
}

struct SearchPastaIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Pasta"
    static let description = IntentDescription(
        "Searches your Pasta history and returns the matching clips, newest and most used first."
    )

    @Parameter(title: "Search For")
    var query: String

    @Parameter(title: "Type")
    var kind: ClipKind?

    @Parameter(title: "Limit", default: 5, inclusiveRange: (1, 50))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search Pasta for \(\.$query)") {
            \.$kind
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let matches = try ShortcutsHistoryStore.history().search(query, contentType: kind?.contentType, limit: limit)
        return .result(value: matches.map(\.content))
    }
}

enum ShortcutsError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText
    case noMatchingClip

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText: return "There is no text to save."
        case .noMatchingClip: return "Pasta has no matching clip yet."
        }
    }
}

struct PastaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyLatestClipIntent(),
            phrases: ["Copy my latest \(.applicationName) clip", "Copy latest clip from \(.applicationName)"],
            shortTitle: "Copy Latest Clip",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: SaveToPastaIntent(),
            phrases: ["Save to \(.applicationName)", "Save text to \(.applicationName)"],
            shortTitle: "Save to Pasta",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: SearchPastaIntent(),
            phrases: ["Search \(.applicationName)", "Search my \(.applicationName) history"],
            shortTitle: "Search Pasta",
            systemImageName: "magnifyingglass"
        )
    }
}
