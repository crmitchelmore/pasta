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

        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0

        guard let store = plist["store"] as? [String: Any],
              let jcList = store["jcList"] as? [[String: Any]] else {
            throw ImportError.unrecognizedSchema(app: "Flycut")
        }

        let totalCount = jcList.count

        for item in jcList {
            current += 1
            do {
                guard let content = item["Contents"] as? String, !content.isEmpty else {
                    skipped += 1
                    progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                    continue
                }

                let timestampValue = item["Timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
                let timestamp = Date(timeIntervalSince1970: timestampValue)
                let sourceApp = item["AppLocalizedName"] as? String

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

        PastaLogger.database.info("Flycut import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
}
#endif
