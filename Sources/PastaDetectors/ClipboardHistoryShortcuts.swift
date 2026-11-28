import Foundation
import PastaCore

/// The history operations behind the iOS Shortcuts actions, kept here so they
/// share the capture policy and can be tested without the app target.
public struct ClipboardHistoryShortcuts: Sendable {
    public static let sourceApp = "Shortcuts"

    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Classifies and stores `text` with the same secret policy as a pasteboard
    /// capture. Returns the stored row, or `nil` when the text is blank.
    @discardableResult
    public func save(_ text: String, syncSensitiveContent: Bool, timestamp: Date = Date()) throws -> ClipboardEntry? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entry = CloudSyncPolicy.applying(
            to: CapturedTextClassifier.entry(content: text, sourceApp: Self.sourceApp, timestamp: timestamp),
            syncSensitiveContent: syncSensitiveContent
        )
        return try database.insert(entry, deduplicate: true).entry
    }

    /// The newest text entry, optionally of one type. Without a type, values
    /// extracted from a larger Mac entry are skipped in favour of whole entries.
    public func latest(contentType: ContentType? = nil) throws -> ClipboardEntry? {
        try database.fetchRecent(contentType: contentType, limit: 50)
            .first { Self.isText($0) && (contentType != nil || !$0.isExtracted) }
    }

    public func search(_ query: String, contentType: ContentType? = nil, limit: Int = 10) throws -> [ClipboardEntry] {
        Array(try database.searchFTS(query: query, contentType: contentType, limit: limit * 2)
            .filter(Self.isText)
            .prefix(limit))
    }

    private static func isText(_ entry: ClipboardEntry) -> Bool {
        ![.image, .screenshot, .filePath].contains(entry.contentType)
    }
}
