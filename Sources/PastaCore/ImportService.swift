import Foundation
import GRDB

/// Represents a clipboard app that can be imported from
public enum ClipboardApp: String, CaseIterable, Identifiable {
    case alfred = "Alfred"
    case maccy = "Maccy"
    case flycut = "Flycut"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .alfred: return "sparkle.magnifyingglass"
        case .maccy: return "doc.on.clipboard"
        case .flycut: return "scissors"
        }
    }
    
    public var description: String {
        switch self {
        case .alfred: return "Alfred Clipboard History"
        case .maccy: return "Maccy (open source)"
        case .flycut: return "Flycut (open source)"
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

/// Service for importing clipboard history from other apps
public final class ImportService {
    private let database: DatabaseManager
    private let imageStorage: ImageStorageManager
    
    public init(database: DatabaseManager, imageStorage: ImageStorageManager) {
        self.database = database
        self.imageStorage = imageStorage
    }
    
    /// Import from a specific clipboard app
    public func importFrom(_ app: ClipboardApp) throws -> ImportResult {
        PastaLogger.database.info("Starting import from \(app.rawValue)")
        
        switch app {
        case .alfred:
            return try importFromAlfred()
        case .maccy:
            return try importFromMaccy()
        case .flycut:
            return try importFromFlycut()
        }
    }
    
    // MARK: - Alfred Import
    
    private func importFromAlfred() throws -> ImportResult {
        let dbPath = ClipboardApp.alfred.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Alfred")
        }
        
        let alfredDb = try DatabaseQueue(path: dbPath)
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        
        // Alfred schema: clipboard(item TEXT, ts DECIMAL, app TEXT, dataType INT, dataHash TEXT)
        // dataType: 0=text, 1=file, 2=image
        try alfredDb.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT item, ts, app, dataType, dataHash FROM clipboard ORDER BY ts DESC")
            
            for row in rows {
                do {
                    let content: String = row["item"] ?? ""
                    let timestamp = Date(timeIntervalSince1970: row["ts"] ?? 0)
                    let sourceApp: String? = row["app"]
                    let dataType: Int = row["dataType"] ?? 0
                    
                    // Skip empty content
                    if content.isEmpty && dataType == 0 {
                        skipped += 1
                        continue
                    }
                    
                    // Check for duplicate
                    if try isDuplicate(content: content, timestamp: timestamp) {
                        skipped += 1
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
                } catch {
                    failed += 1
                    if errors.count < 5 {
                        errors.append(error.localizedDescription)
                    }
                }
            }
        }
        
        PastaLogger.database.info("Alfred import complete: \(imported) imported, \(skipped) skipped, \(failed) failed")
        return ImportResult(imported: imported, skipped: skipped, failed: failed, errors: errors)
    }
    
    // MARK: - Maccy Import
    
    private func importFromMaccy() throws -> ImportResult {
        let dbPath = ClipboardApp.maccy.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ImportError.databaseNotFound(app: "Maccy")
        }
        
        let maccyDb = try DatabaseQueue(path: dbPath)
        var imported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []
        
        // Maccy uses SwiftData/Core Data. The schema has:
        // ZHISTORYITEM (Z_PK, ZAPPLICATION, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZNUMBEROFCOPIES)
        // ZHISTORYITEMCONTENT (Z_PK, ZITEM, ZTYPE, ZVALUE)
        try maccyDb.read { db in
            // Check if tables exist (SwiftData naming)
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            
            // Try SwiftData naming first
            let itemsTable = tables.contains("ZHISTORYITEM") ? "ZHISTORYITEM" : 
                            (tables.contains("HistoryItem") ? "HistoryItem" : nil)
            let contentsTable = tables.contains("ZHISTORYITEMCONTENT") ? "ZHISTORYITEMCONTENT" :
                               (tables.contains("HistoryItemContent") ? "HistoryItemContent" : nil)
            
            guard let itemsTable, let contentsTable else {
                throw ImportError.unrecognizedSchema(app: "Maccy")
            }
            
            // Fetch items with their content
            let sql = """
                SELECT i.*, c.ZTYPE as contentType, c.ZVALUE as contentValue
                FROM \(itemsTable) i
                LEFT JOIN \(contentsTable) c ON c.ZITEM = i.Z_PK
                WHERE c.ZTYPE = 'public.utf8-plain-text'
                ORDER BY i.ZLASTCOPIEDAT DESC
            """
            
            let rows = try Row.fetchAll(db, sql: sql)
            
            for row in rows {
                do {
                    guard let valueData: Data = row["contentValue"],
                          let content = String(data: valueData, encoding: .utf8),
                          !content.isEmpty else {
                        skipped += 1
                        continue
                    }
                    
                    // Maccy stores dates as Core Data timestamps (seconds since 2001-01-01)
                    let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)
                    let timestampValue: Double = row["ZLASTCOPIEDAT"] ?? row["ZFIRSTCOPIEDAT"] ?? 0
                    let timestamp = Date(timeInterval: timestampValue, since: coreDataEpoch)
                    
                    let sourceApp: String? = row["ZAPPLICATION"]
                    let copyCount: Int = row["ZNUMBEROFCOPIES"] ?? 1
                    
                    if try isDuplicate(content: content, timestamp: timestamp) {
                        skipped += 1
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
    
    private func importFromFlycut() throws -> ImportResult {
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
        
        // Flycut structure: { "store": { "jcList": [ { "Contents": "...", "Timestamp": ..., "AppLocalizedName": "..." } ] } }
        guard let store = plist["store"] as? [String: Any],
              let jcList = store["jcList"] as? [[String: Any]] else {
            throw ImportError.unrecognizedSchema(app: "Flycut")
        }
        
        for item in jcList {
            do {
                guard let content = item["Contents"] as? String, !content.isEmpty else {
                    skipped += 1
                    continue
                }
                
                let timestampValue = item["Timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
                let timestamp = Date(timeIntervalSince1970: timestampValue)
                let sourceApp = item["AppLocalizedName"] as? String
                
                if try isDuplicate(content: content, timestamp: timestamp) {
                    skipped += 1
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
    
    // MARK: - Helpers
    
    private func isDuplicate(content: String, timestamp: Date) throws -> Bool {
        // Check if we already have this exact content
        let hash = ClipboardEntry.sha256Hex(content)
        let existing = try database.fetchAll()
        return existing.contains { $0.contentHash == hash }
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
