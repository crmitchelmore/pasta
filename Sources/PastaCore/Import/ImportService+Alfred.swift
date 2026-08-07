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

        // Get total count first for batching
        let totalCount = try alfredDb.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboard") ?? 0
        }

        let batcher = makeBatcher(total: totalCount, progress: progress)
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
                        do {
                            let content: String = row["item"] ?? ""
                            let timestamp = Date(timeIntervalSince1970: row["ts"] ?? 0)
                            let sourceApp: String? = row["app"]
                            let dataType: Int = row["dataType"] ?? 0

                            // Skip empty content
                            if content.isEmpty && dataType == 0 {
                                batcher.skip()
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
                                    batcher.skip()
                                    continue
                                }
                            } else if dataType == 1 {
                                // File path
                                contentType = .filePath
                            }

                            batcher.add(ClipboardEntry(
                                content: content,
                                contentType: contentType,
                                rawData: rawData,
                                imagePath: imagePath,
                                timestamp: timestamp,
                                copyCount: 1,
                                sourceApp: sourceApp
                            ))
                        } catch {
                            batcher.fail(error)
                        }
                    }
                }
            }
            offset += batchSize
        }

        let result = batcher.finish()
        PastaLogger.database.info("Alfred import complete: \(result.imported) imported, \(result.skipped) skipped, \(result.failed) failed")
        return result
    }
}
#endif
