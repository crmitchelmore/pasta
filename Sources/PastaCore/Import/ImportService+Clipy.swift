#if os(macOS)
import Foundation

extension ImportService {
    func importFromClipy(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let realmPath = ClipboardApp.clipy.databasePath
        guard FileManager.default.fileExists(atPath: realmPath) else {
            throw ImportError.databaseNotFound(app: "Clipy")
        }

        // Clipy uses Realm database - we can't read it directly without Realm SDK
        // But Clipy also stores recent clips in UserDefaults
        let defaults = UserDefaults(suiteName: "com.clipy-app.Clipy")

        // Try to read from UserDefaults history
        let historyData = defaults?.array(forKey: "kCPYPrefHistoryKey") as? [[String: Any]]
        let batcher = makeBatcher(total: historyData?.count ?? 0, progress: progress)

        if let historyData {
            for item in historyData {
                guard let content = item["string"] as? String ?? item["data"] as? String,
                      !content.isEmpty else {
                    batcher.skip()
                    continue
                }

                batcher.add(ClipboardEntry(
                    content: content,
                    contentType: .text,
                    timestamp: (item["date"] as? Date) ?? Date(),
                    copyCount: 1,
                    sourceApp: nil
                ))
            }
        } else {
            // Realm DB exists but we can't read it - inform user
            batcher.note("Clipy uses Realm database format which requires special handling. Only UserDefaults history was checked.")
        }

        let result = batcher.finish()
        PastaLogger.database.info("Clipy import complete: \(result.imported) imported, \(result.skipped) skipped, \(result.failed) failed")
        return result
    }
}
#endif
