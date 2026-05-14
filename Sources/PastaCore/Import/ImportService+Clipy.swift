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

        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0

        // Try to read from UserDefaults history
        if let historyData = defaults?.array(forKey: "kCPYPrefHistoryKey") as? [[String: Any]] {
            let totalCount = historyData.count

            for item in historyData {
                current += 1
                do {
                    guard let content = item["string"] as? String ?? item["data"] as? String,
                          !content.isEmpty else {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }

                    let timestamp = (item["date"] as? Date) ?? Date()

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
        } else {
            // Realm DB exists but we can't read it - inform user
            errors.append("Clipy uses Realm database format which requires special handling. Only UserDefaults history was checked.")
        }

        PastaLogger.database.info("Clipy import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
}
#endif
