#if os(macOS)
import Foundation
import GRDB

/// Represents a clipboard app that can be imported from
public enum ClipboardApp: String, CaseIterable, Identifiable {
    case alfred = "Alfred"
    case maccy = "Maccy"
    case flycut = "Flycut"
    case copyClip = "CopyClip"
    case paste = "Paste"
    case pastebot = "Pastebot"
    case clipy = "Clipy"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .alfred: return "sparkle.magnifyingglass"
        case .maccy: return "doc.on.clipboard"
        case .flycut: return "scissors"
        case .copyClip: return "paperclip"
        case .paste: return "doc.on.doc"
        case .pastebot: return "robot"
        case .clipy: return "clipboard"
        }
    }
    
    public var description: String {
        switch self {
        case .alfred: return "Alfred Clipboard History"
        case .maccy: return "Maccy (open source)"
        case .flycut: return "Flycut (open source)"
        case .copyClip: return "CopyClip / CopyClip 2"
        case .paste: return "Paste by Widetape"
        case .pastebot: return "Pastebot by Tapbots"
        case .clipy: return "Clipy (open source)"
        }
    }
    
    /// Check if this app's data is available for import
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: databasePath)
    }
    
    var databasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .alfred:
            return "\(home)/Library/Application Support/Alfred/Databases/clipboard.alfdb"
        case .maccy:
            return "\(home)/Library/Application Support/Maccy/Storage.sqlite"
        case .flycut:
            return "\(home)/Library/Preferences/net.sogao.Flycut.plist"
        case .copyClip:
            return "\(home)/Library/Application Support/com.fiplab.copyclip2/Data/com.fiplab.copyclip2.data"
        case .paste:
            return "\(home)/Library/Containers/com.widetape.Paste/Data/Library/Application Support/Paste/Paste.sqlite"
        case .pastebot:
            return "\(home)/Library/Group Containers/9272N75U7L.com.tapbots.Pastebot/Pastebot.sqlite"
        case .clipy:
            return "\(home)/Library/Application Support/com.clipy-app.Clipy/default.realm"
        }
    }
}

/// Result of an import operation
public struct ImportResult {
    public let imported: Int
    public let skipped: Int
    public let failed: Int
    public let errors: [String]
    
    public var summary: String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) imported") }
        if skipped > 0 { parts.append("\(skipped) duplicates skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "No items found" : parts.joined(separator: ", ")
    }
}

/// Progress callback for import operations
public struct ImportProgress: Sendable {
    public let current: Int
    public let total: Int
    public let imported: Int
    public let skipped: Int
    
    public var fraction: Double {
        total > 0 ? Double(current) / Double(total) : 0
    }
}

/// Result of an export operation
public struct ExportResult {
    public let exported: Int
    public let fileURL: URL
}

/// Service for importing clipboard history from other apps
public final class ImportService {
    private let database: DatabaseManager
    private let imageStorage: ImageStorageManager
    
    public init(database: DatabaseManager, imageStorage: ImageStorageManager) {
        self.database = database
        self.imageStorage = imageStorage
    }
    
    /// Import from a specific clipboard app with progress callback
    public func importFrom(_ app: ClipboardApp, progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        PastaLogger.database.info("Starting import from \(app.rawValue)")
        
        switch app {
        case .alfred:
            return try importFromAlfred(progress: progress)
        case .maccy:
            return try importFromMaccy(progress: progress)
        case .flycut:
            return try importFromFlycut(progress: progress)
        case .copyClip:
            return try importFromCopyClip(progress: progress)
        case .paste:
            return try importFromPaste(progress: progress)
        case .pastebot:
            return try importFromPastebot(progress: progress)
        case .clipy:
            return try importFromClipy(progress: progress)
        }
    }
    
    /// Import from a specific clipboard app (convenience method without progress)
    public func importFrom(_ app: ClipboardApp) throws -> ImportResult {
        try importFrom(app) { _ in }
    }

    /// Export all clipboard history to a JSON file.
    public func exportAllEntries(to fileURL: URL) throws -> ExportResult {
        struct ExportPayload: Codable {
            let formatVersion: Int
            let exportedAt: Date
            let entries: [ClipboardEntry]
        }

        let entries = try database.fetchAll()
        let payload = ExportPayload(
            formatVersion: 1,
            exportedAt: Date(),
            entries: entries
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)

        PastaLogger.database.info("Exported \(entries.count) entries to \(fileURL.path)")
        return ExportResult(exported: entries.count, fileURL: fileURL)
    }
    
    // MARK: - Alfred Import
    
    private func importFromAlfred(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
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
    
    // MARK: - Maccy Import
    
    private func importFromMaccy(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
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
    
    // MARK: - Flycut Import
    
    private func importFromFlycut(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
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
    
    // MARK: - CopyClip Import
    
    private func importFromCopyClip(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
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
    
    // MARK: - Paste Import
    
    private func importFromPaste(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.paste.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Paste")
        }
        
        let pasteDb = try DatabaseQueue(path: dbPath)
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0
        
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
            let totalCount = rows.count
            
            for row in rows {
                current += 1
                do {
                    // Try various column names for content
                    let content = (row["plainText"] as String?) ??
                                 (row["ZPLAINTEXT"] as String?) ??
                                 (row["ZTEXT"] as String?) ??
                                 (row["ZCONTENT"] as String?) ?? ""
                    
                    if content.isEmpty {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }
                    
                    // Core Data timestamp
                    let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                    let timestampValue: Double = row["ZCREATETIME"] ?? row["ZTIMESTAMP"] ?? 0
                    let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)
                    
                    let sourceApp: String? = row["ZAPPNAME"] ?? row["ZSOURCEAPP"]
                    
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
        }
        
        PastaLogger.database.info("Paste import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
    
    // MARK: - Pastebot Import
    
    private func importFromPastebot(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
        let dbPath = ClipboardApp.pastebot.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Pastebot")
        }
        
        let pastebotDb = try DatabaseQueue(path: dbPath)
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var current = 0
        
        try pastebotDb.read { db in
            // Pastebot uses Core Data - look for clippings table
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            
            let clippingsTable = tables.first { $0.uppercased().contains("CLIPPING") || $0.uppercased().contains("PASTE") }
            
            guard let clippingsTable else {
                throw ImportError.unrecognizedSchema(app: "Pastebot")
            }
            
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(clippingsTable) ORDER BY ZDATE DESC")
            let totalCount = rows.count
            
            for row in rows {
                current += 1
                do {
                    // Try various column names
                    let content = (row["ZPLAINTEXT"] as String?) ??
                                 (row["ZTEXT"] as String?) ??
                                 (row["ZTITLE"] as String?) ?? ""
                    
                    if content.isEmpty {
                        skipped += 1
                        progress(ImportProgress(current: current, total: totalCount, imported: imported, skipped: skipped))
                        continue
                    }
                    
                    let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                    let timestampValue: Double = row["ZDATE"] ?? row["ZCREATED"] ?? 0
                    let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)
                    
                    let sourceApp: String? = row["ZAPPNAME"] ?? row["ZSOURCE"]
                    
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
        }
        
        PastaLogger.database.info("Pastebot import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
    
    // MARK: - Clipy Import
    
    private func importFromClipy(progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportResult {
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
    
    // MARK: - Helpers
    
    private func isDuplicate(content: String, timestamp: Date) throws -> Bool {
        // Check if we already have this exact content using efficient hash lookup
        let hash = ClipboardEntry.sha256Hex(content)
        return try database.existsWithHash(hash)
    }
}

// MARK: - Import Errors

public enum ImportError: LocalizedError {
    case databaseNotFound(app: String)
    case unrecognizedSchema(app: String)
    
    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let app):
            return "Could not find \(app) database"
        case .unrecognizedSchema(let app):
            return "Unrecognized \(app) database format"
        }
    }
}
#endif
