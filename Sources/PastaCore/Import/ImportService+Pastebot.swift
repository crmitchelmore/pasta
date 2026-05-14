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
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0

        try pastebotDb.read { db in
            // Pastebot uses Core Data - look for clippings table
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")

            let clippingsTable = tables.first { $0.uppercased().contains("CLIPPING") || $0.uppercased().contains("PASTE") }

            guard let clippingsTable else {
                throw ImportError.unrecognizedSchema(app: "Pastebot")
            }

            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(clippingsTable) ORDER BY ZDATE DESC")
            let totalCount = rows.count

            for row in rows {
                current += 1
                do {
                    // Try various column names
                    let content = (row["ZPLAINTEXT"] as String?) ??
                                 (row["ZTEXT"] as String?) ??
                                 (row["ZTITLE"] as String?) ?? ""

                    if content.isEmpty {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }

                    let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                    let timestampValue: Double = row["ZDATE"] ?? row["ZCREATED"] ?? 0
                    let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)

                    let sourceApp: String? = row["ZAPPNAME"] ?? row["ZSOURCE"]

                    if try isDuplicate(content: content, timestamp: timestamp) {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }

                    let entry = ClipboardEntry(
                        content: content,
                        contentType: .text,
                        timestamp: timestamp,
                        copyCount: 1,
                        sourceApp: sourceApp
                    )

                    try database.insert(entry)
                    imported += 1
                    progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                } catch {
                    failed += 1
                    if errors.count < 5 {
                        errors.append(error.localizedDescription)
                    }
                }
            }
        }

        PastaLogger.database.info("Pastebot import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
}
#endif
