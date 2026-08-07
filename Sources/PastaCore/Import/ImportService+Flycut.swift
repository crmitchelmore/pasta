#if os(macOS)
import Foundation

extension ImportService {
    func importFromFlycut(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let plistPath = ClipboardApp.flycut.databasePath
        guard FileManager.default.fileExists(atPath: plistPath) else {
            throw ImportError.databaseNotFound(app: "Flycut")
        }

        guard let plistData = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw ImportError.unrecognizedSchema(app: "Flycut")
        }

        guard let store = plist["store"] as? [String: Any],
              let jcList = store["jcList"] as? [[String: Any]] else {
            throw ImportError.unrecognizedSchema(app: "Flycut")
        }

        let batcher = makeBatcher(total: jcList.count, progress: progress)

        for item in jcList {
            guard let content = item["Contents"] as? String, !content.isEmpty else {
                batcher.skip()
                continue
            }

            let timestampValue = item["Timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
            let timestamp = Date(timeIntervalSince1970: timestampValue)
            let sourceApp = item["AppLocalizedName"] as? String

            batcher.add(ClipboardEntry(
                content: content,
                contentType: .text,
                timestamp: timestamp,
                copyCount: 1,
                sourceApp: sourceApp
            ))
        }

        let result = batcher.finish()
        PastaLogger.database.info("Flycut import complete: \(result.imported) imported, \(result.skipped) skipped, \(result.failed) failed")
        return result
    }
}
#endif
