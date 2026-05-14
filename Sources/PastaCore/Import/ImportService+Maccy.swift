#if os(macOS)
import Foundation
import GRDB

extension ImportService {
    func importFromMaccy(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.maccy.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Maccy")
        }

        let maccyDb = try DatabaseQueue(path: dbPath)
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0

        try maccyDb.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")

            let itemsTable = tables.contains("ZHISTORYITEM") ? "ZHISTORYITEM" :
                            (tables.contains("HistoryItem") ? "HistoryItem" : nil)
            let contentsTable = tables.contains("ZHISTORYITEMCONTENT") ? "ZHISTORYITEMCONTENT" :
                               (tables.contains("HistoryItemContent") ? "HistoryItemContent" : nil)

            guard let itemsTable, let contentsTable else {
                throw ImportError.unrecognizedSchema(app: "Maccy")
            }

            let sql = """
                SELECT i.*, c.ZTYPE as contentType, c.ZVALUE as contentValue
                FROM \(itemsTable) i
                LEFT JOIN \(contentsTable) c ON c.ZITEM = i.Z_PK
                WHERE c.ZTYPE = 'public.utf8-plain-text'
                ORDER BY i.ZLASTCOPIEDAT DESC
            """

            let rows = try Row.fetchAll(db, sql: sql)
            let totalCount = rows.count

            for row in rows {
                current += 1
                do {
                    guard let valueData: Data = row["contentValue"],
                          let content = String(data: valueData, encoding: .utf8),
                          !content.isEmpty else {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }

                    let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                    let timestampValue: Double = row["ZLASTCOPIEDAT"] ?? row["ZFIRSTCOPIEDAT"] ?? 0
                    let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)

                    let sourceApp: String? = row["ZAPPLICATION"]
                    let copyCount: Int = row["ZNUMBEROFCOPIES"] ?? 1

                    if try isDuplicate(content: content, timestamp: timestamp) {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }

                    let entry = ClipboardEntry(
                        content: content,
                        contentType: .text,
                        timestamp: timestamp,
                        copyCount: copyCount,
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

        PastaLogger.database.info("Maccy import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
}
#endif
