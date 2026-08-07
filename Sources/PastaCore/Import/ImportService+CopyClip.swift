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
        let batcher = makeBatcher(total: extractedItems.count, progress: progress)

        for (content, date) in extractedItems {
            batcher.add(ClipboardEntry(
                content: content,
                contentType: .text,
                timestamp: date ?? Date(),
                copyCount: 1,
                sourceApp: nil
            ))
        }

        let result = batcher.finish()
        PastaLogger.database.info("CopyClip import complete: \(result.imported) imported, \(result.skipped) skipped, \(result.failed) failed")
        return result
    }
}
#endif
