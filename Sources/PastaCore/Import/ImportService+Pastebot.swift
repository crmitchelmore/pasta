#if os(macOS)
import Foundation
import GRDB

extension ImportService {
    func importFromPastebot(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.pastebot.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Pastebot")
        }

        let pastebotDb = try DatabaseQueue(path: dbPath)
        var result = ImportResult(imported: 0, skipped: 0, failed: 0, errors: [])

        try pastebotDb.read { db in
            // Pastebot uses Core Data - look for clippings table
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")

            let clippingsTable = tables.first { $0.uppercased().contains("CLIPPING") || $0.uppercased().contains("PASTE") }

            guard let clippingsTable else {
                throw ImportError.unrecognizedSchema(app: "Pastebot")
            }

            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(clippingsTable) ORDER BY ZDATE DESC")
            let batcher = makeBatcher(total: rows.count, progress: progress)

            for row in rows {
                // Try various column names
                let content = (row["ZPLAINTEXT"] as String?) ??
                             (row["ZTEXT"] as String?) ??
                             (row["ZTITLE"] as String?) ?? ""

                if content.isEmpty {
                    batcher.skip()
                    continue
                }

                let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                let timestampValue: Double = row["ZDATE"] ?? row["ZCREATED"] ?? 0
                let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)

                let sourceApp: String? = row["ZAPPNAME"] ?? row["ZSOURCE"]

                batcher.add(ClipboardEntry(
                    content: content,
                    contentType: .text,
                    timestamp: timestamp,
                    copyCount: 1,
                    sourceApp: sourceApp
                ))
            }

            result = batcher.finish()
        }

        PastaLogger.database.info("Pastebot import complete: \(result.imported) imported, \(result.skipped) skipped, \(result.failed) failed")
        return result
    }
}
#endif
