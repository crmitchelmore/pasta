#if os(macOS)
import Foundation
import GRDB

extension ImportService {
    func importFromAlfred(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.alfred.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Alfred")
        }

        let alfredDb = try DatabaseQueue(path: dbPath)
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0

        // Get total count first for batching
        let totalCount = try alfredDb.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard") ?? 0
        }

        let batchSize = 500
        var offset = 0

        while offset < totalCount {
            try autoreleasepool {
                try alfredDb.read { db in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT item, ts, app, dataType, dataHash FROM clipboard
                        ORDER BY ts DESC
                        LIMIT ? OFFSET ?
                        """, arguments: [batchSize, offset])

                    for row in rows {
                        current += 1

                        do {
                            let content: String = row["item"] ?? ""
                            let timestamp = Date(timeIntervalSince1970: row["ts"] ?? 0)
                            let sourceApp: String? = row["app"]
                            let dataType: Int = row["dataType"] ?? 0

                            // Skip empty content
                            if content.isEmpty && dataType == 0 {
                                skipped += 1
                                progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                                continue
                            }

                            // Check for duplicate using efficient hash lookup
                            if try isDuplicate(content: content, timestamp: timestamp) {
                                skipped += 1
                                progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                                continue
                            }

                            var contentType: ContentType = .text
                            var imagePath: String? = nil
                            var rawData: Data? = nil

                            if dataType == 2 {
                                // Image - check for TIFF file in clipboard.alfdb.data/
                                let dataDir = dbPath + ".data"
                                let hash: String = row["dataHash"] ?? ""
                                let tiffPath = "\(dataDir)/\(hash).tiff"

                                if FileManager.default.fileExists(atPath: tiffPath),
                                   let imageData = FileManager.default.contents(atPath: tiffPath) {
                                    contentType = .image
                                    rawData = imageData
                                    imagePath = try imageStorage.saveImage(imageData)
                                } else {
                                    // Image file not found, skip
                                    skipped += 1
                                    progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                                    continue
                                }
                            } else if dataType == 1 {
                                // File path
                                contentType = .filePath
                            }

                            let entry = ClipboardEntry(
                                content: content,
                                contentType: contentType,
                                rawData: rawData,
                                imagePath: imagePath,
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
            }
            offset += batchSize
        }

        PastaLogger.database.info("Alfred import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
}
#endif
