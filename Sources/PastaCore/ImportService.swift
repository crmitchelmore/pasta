#if os(macOS)
import Foundation
import GRDB

/// Service for importing clipboard history from other apps.
///
/// The per-source import implementations live in the `Import/` directory as
/// extensions on this type (e.g. `ImportService+Maccy.swift`).
public final class ImportService {
    let database: DatabaseManager
    let imageStorage: ImageStorageManager

    public init(database: DatabaseManager, imageStorage: ImageStorageManager) {
        self.database = database
        self.imageStorage = imageStorage
    }

    /// Import from a specific clipboard app with progress callback
    public func importFrom(_ app: ClipboardApp, progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        PastaLogger.database.info("Starting import from \(app.rawValue)")

        switch app {
        case .alfred:
            return try importFromAlfred(progress: progress)
        case .maccy:
            return try importFromMaccy(progress: progress)
        case .flycut:
            return try importFromFlycut(progress: progress)
        case .copyClip:
            return try importFromCopyClip(progress: progress)
        case .paste:
            return try importFromPaste(progress: progress)
        case .pastebot:
            return try importFromPastebot(progress: progress)
        case .clipy:
            return try importFromClipy(progress: progress)
        }
    }

    /// Import from a specific clipboard app (convenience method without progress)
    public func importFrom(_ app: ClipboardApp) throws -> ImportResult {
        try importFrom(app) { _ in }
    }

    /// Export all clipboard history to a JSON file.
    public func exportAllEntries(to fileURL: URL) throws -> ExportResult {
        struct ExportPayload: Codable {
            let formatVersion: Int
            let exportedAt: Date
            let entries: [ClipboardEntry]
        }

        let entries = try database.fetchAll()
        let payload = ExportPayload(
            formatVersion: 1,
            exportedAt: Date(),
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)

        PastaLogger.database.info("Exported \(entries.count) entries to \(fileURL.path)")
        return ExportResult(exported: entries.count, fileURL: fileURL)
    }

    // MARK: - Helpers

    func isDuplicate(content: String, timestamp: Date) throws -> Bool {
        // Check if we already have this exact content using efficient hash lookup
        let hash = ClipboardEntry.sha256Hex(content)
        return try database.existsWithHash(hash)
    }
}
#endif
