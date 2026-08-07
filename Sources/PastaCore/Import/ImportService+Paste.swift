#if os(macOS)
import Foundation
import GRDB

extension ImportService {
    func importFromPaste(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.paste.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Paste")
        }

        let pasteDb = try DatabaseQueue(path: dbPath)
        var result = ImportResult(imported: 0, skipped: 0, failed: 0, errors: [])

        // Paste uses Core Data with tables like ZITEM, ZITEMCONTENT
        try pasteDb.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")

            // Find the main items table
            let itemsTable = tables.first { $0.uppercased().contains("ITEM") && !$0.uppercased().contains("CONTENT") }
            let contentsTable = tables.first { $0.uppercased().contains("CONTENT") }

            guard let itemsTable else {
                throw ImportError.unrecognizedSchema(app: "Paste")
            }

            // Try to query items - Paste schema varies by version
            let sql: String
            if let contentsTable {
                sql = """
                    SELECT i.*, c.ZPLAINTEXT as plainText, c.ZRICHTEXT as richText
                    FROM \(itemsTable) i
                    LEFT JOIN \(contentsTable) c ON c.ZITEM = i.Z_PK
                    ORDER BY i.ZCREATETIME DESC
                """
            } else {
                sql = "SELECT * FROM \(itemsTable) ORDER BY ZCREATETIME DESC"
            }

            let rows = try Row.fetchAll(db, sql: sql)
            let batcher = makeBatcher(total: rows.count, progress: progress)

            for row in rows {
                // Try various column names for content
                let content = (row["plainText"] as String?) ??
                             (row["ZPLAINTEXT"] as String?) ??
                             (row["ZTEXT"] as String?) ??
                             (row["ZCONTENT"] as String?) ?? ""

                if content.isEmpty {
                    batcher.skip()
                    continue
                }

                // Core Data timestamp
                let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                let timestampValue: Double = row["ZCREATETIME"] ?? row["ZTIMESTAMP"] ?? 0
                let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)

                let sourceApp: String? = row["ZAPPNAME"] ?? row["ZSOURCEAPP"]

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

        PastaLogger.database.info("Paste import complete: \(result.imported) imported, \(result.skipped) skipped, \(result.failed) failed")
        return result
    }
}
#endif
