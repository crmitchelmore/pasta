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

    /// Creates a batcher bound to this service's database.
    func makeBatcher(total: Int, progress: @escaping @Sendable (ImportProgress) -> Void) -> ImportBatcher {
        ImportBatcher(database: database, total: total, progress: progress)
    }
}

/// Accumulates rows produced by an importer and writes them in single-transaction
/// chunks via `DatabaseManager.insertBatch`.
///
/// Importers used to pay a duplicate-check read *plus* its own write transaction
/// for every single row, and to fire the progress callback (which hops to the
/// main queue) per row too. Both are now amortised over `chunkSize` rows.
final class ImportBatcher {
    /// Rows buffered before a flush, and the progress-reporting granularity.
    static let chunkSize = 500

    private let database: DatabaseManager
    private let total: Int
    private let progress: (ImportProgress) -> Void
    private var pending: [ClipboardEntry] = []

    private(set) var current = 0
    private(set) var imported = 0
    private(set) var skipped = 0
    private(set) var failed = 0
    private(set) var errors: [String] = []

    init(database: DatabaseManager, total: Int, progress: @escaping (ImportProgress) -> Void) {
        self.database = database
        self.total = total
        self.progress = progress
        self.pending.reserveCapacity(Self.chunkSize)
    }

    /// Records a row that yielded an entry to import.
    func add(_ entry: ClipboardEntry) {
        current += 1
        pending.append(entry)
        if pending.count >= Self.chunkSize {
            flush()
        } else {
            reportIfDue()
        }
    }

    /// Records a row that was deliberately not imported (empty/unusable content).
    func skip() {
        current += 1
        skipped += 1
        reportIfDue()
    }

    /// Records a row that failed to parse or import.
    func fail(_ error: Error) {
        current += 1
        failed += 1
        appendError(error.localizedDescription)
        reportIfDue()
    }

    /// Records a non-row-specific problem worth surfacing to the user.
    func note(_ message: String) {
        appendError(message)
    }

    /// Flushes any buffered rows and produces the final result.
    func finish() -> ImportResult {
        flush()
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }

    private func flush() {
        guard !pending.isEmpty else {
            report()
            return
        }

        do {
            let result = try database.insertBatch(pending, deduplicate: true)
            imported += result.inserted
            skipped += result.skipped
        } catch {
            failed += pending.count
            appendError(error.localizedDescription)
        }

        pending.removeAll(keepingCapacity: true)
        report()
    }

    private func appendError(_ message: String) {
        if errors.count < 5 {
            errors.append(message)
        }
    }

    private func reportIfDue() {
        if current % Self.chunkSize == 0 {
            report()
        }
    }

    private func report() {
        progress(ImportProgress(current: current, total: total, imported: imported, skipped: skipped))
    }
}
#endif
