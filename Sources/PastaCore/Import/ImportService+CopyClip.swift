#if os(macOS)
import Foundation

extension ImportService {
    func importFromCopyClip(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.copyClip.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "CopyClip")
        }

        // CopyClip 2 uses a binary plist/archive format
        guard let data = FileManager.default.contents(atPath: dbPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            throw ImportError.unrecognizedSchema(app: "CopyClip")
        }

        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0

        // CopyClip stores items in various formats - try to extract text items
        func extractItems(from obj: Any) -> [(content: String, date: Date?)] {
            var items: [(String, Date?)] = []

            if let dict = obj as? [String: Any] {
                // Check for content field
                if let content = dict["content"] as? String ?? dict["string"] as? String ?? dict["text"] as? String,
                   !content.isEmpty {
                    let date = (dict["date"] ?? dict["timestamp"] ?? dict["createdAt"]) as? Date
                    items.append((content, date))
                }
                // Recurse into nested structures
                for (_, value) in dict {
                    items.append(contentsOf: extractItems(from: value))
                }
            } else if let array = obj as? [Any] {
                for item in array {
                    items.append(contentsOf: extractItems(from: item))
                }
            }

            return items
        }

        let extractedItems = extractItems(from: plist)
        let totalCount = extractedItems.count

        for (content, date) in extractedItems {
            current += 1
            do {
                let timestamp = date ?? Date()

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
                    sourceApp: nil
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

        PastaLogger.database.info("CopyClip import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
}
#endif
