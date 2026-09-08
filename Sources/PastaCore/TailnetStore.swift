import Foundation
import GRDB

public struct TailnetPeer: Codable, Identifiable, Equatable, Sendable {
    public var id: String // stable Tailscale node ID, not the mutable hostname/address
    public var localNodeID: String = ""
    public var name: String
    public var address: String
    public var pairingID: UUID
    public var sendEnabled = true
    public var forwardReceived = false
    public var publishToCloud = false
    public var replaceClipboard = false
    public var approvalBytes: Int64 = 50_000_000
    public var receiveLimitBytes: Int64 = 1_000_000_000
    public var cursor: Int64 = 0

    public init(id: String, name: String, address: String, pairingID: UUID = UUID()) {
        self.id = id; self.name = name; self.address = address; self.pairingID = pairingID
    }
}

public enum TailnetTransferState: String, Codable, Sendable {
    case pending, approval, declined, sent, failed
}

public struct TailnetTransfer: Identifiable, Sendable {
    public var id: UUID
    public var peerID: String
    public var title: String
    public var state: TailnetTransferState
    public var backfill: Bool
    public var detail: String?
    public var approvedDigest: String?
}

/// Shares the history database's transaction boundary. Receipts deliberately have
/// no foreign key to history: deleting history must not let an offline retry restore it.
public final class TailnetStore: @unchecked Sendable {
    public let database: DatabaseManager
    private var writer: any DatabaseWriter { database.databaseWriterForSnippets }
    public init(database: DatabaseManager) { self.database = database }

    public func peers() throws -> [TailnetPeer] {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT configuration FROM tailnet_peers ORDER BY nodeID")
                .map { try JSONDecoder().decode(TailnetPeer.self, from: $0) }
        }
    }

    public func save(_ value: TailnetPeer, newPair: Bool = false) throws {
        try writer.write { db in
            var peer = value
            if newPair {
                peer.cursor = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) FROM tailnet_journal") ?? 0
                try db.execute(sql: "DELETE FROM tailnet_queue WHERE nodeID = ?", arguments: [peer.id])
            } else if let data = try Data.fetchOne(db, sql: "SELECT configuration FROM tailnet_peers WHERE nodeID = ?", arguments: [peer.id]) {
                peer.cursor = try JSONDecoder().decode(TailnetPeer.self, from: data).cursor
            }
            try Self.persist(peer, db: db)
        }
    }
    private static func persist(_ peer: TailnetPeer, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO tailnet_peers (nodeID, configuration) VALUES (?, ?)",
                       arguments: [peer.id, try JSONEncoder().encode(peer)])
    }
    public func remove(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM tailnet_peers WHERE nodeID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tailnet_queue WHERE nodeID = ?", arguments: [id])
        }
    }

    /// Newness is insertion order, not the item's clock or recopy timestamp.
    public func enqueue(for id: String, backfill: Bool = false) throws {
        try writer.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT configuration FROM tailnet_peers WHERE nodeID = ?", arguments: [id]) else { return }
            var peer = try JSONDecoder().decode(TailnetPeer.self, from: data)
            guard peer.sendEnabled else { return }
            let maximum = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) FROM tailnet_journal") ?? 0
            try db.execute(sql: """
                INSERT OR IGNORE INTO tailnet_queue (nodeID, entryID, backfill)
                SELECT ?, e.id, ? FROM tailnet_journal j JOIN clipboard_entries e ON e.id = j.entryID
                WHERE j.sequence > ? AND j.sequence <= ? AND (? OR e.receivedViaTailnet = 0)
                """, arguments: [id, backfill, backfill ? 0 : peer.cursor, maximum, peer.forwardReceived])
            peer.cursor = maximum
            try Self.persist(peer, db: db)
        }
    }

    public func transfers(peerID: String? = nil, state: TailnetTransferState? = nil, limit: Int = 100) throws -> [TailnetTransfer] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT q.*, e.content AS entryContent, e.contentType AS entryType FROM tailnet_queue q JOIN clipboard_entries e ON e.id = q.entryID
                WHERE (? IS NULL OR nodeID = ?) AND (? IS NULL OR state = ?)
                ORDER BY CASE q.state WHEN 'approval' THEN 0 WHEN 'failed' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 ELSE 4 END, CASE WHEN q.state = 'sent' THEN -q.rowid ELSE q.rowid END LIMIT ?
                """, arguments: [peerID, peerID, state?.rawValue, state?.rawValue, limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["entryID"]), let state = TailnetTransferState(rawValue: row["state"]) else { return nil }
                let content: String = row["entryContent"]
                let type: String = row["entryType"]
                let title = type == "filePath" ? URL(fileURLWithPath: content.components(separatedBy: "\n").first ?? content).lastPathComponent : (content.isEmpty ? type.capitalized : String(content.prefix(80)))
                return TailnetTransfer(id: id, peerID: row["nodeID"], title: title, state: state, backfill: row["backfill"], detail: row["detail"], approvedDigest: row["approvedDigest"])
            }
        }
    }
    public func setState(_ transfer: TailnetTransfer, _ state: TailnetTransferState, detail: String? = nil, digest: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE tailnet_queue SET state = ?, detail = ?, approvedDigest = COALESCE(?, approvedDigest) WHERE nodeID = ? AND entryID = ?",
                           arguments: [state.rawValue, detail, digest, transfer.peerID, transfer.id.uuidString])
        }
    }
    public func hasReceived(_ id: UUID) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tailnet_receipts WHERE entryID = ?) OR EXISTS(SELECT 1 FROM tailnet_journal WHERE entryID = ?)", arguments: [id.uuidString, id.uuidString]) ?? false
        }
    }
    /// Atomically receives once. Existing local versions, pins and timestamps win.
    @discardableResult
    public func receive(_ entry: ClipboardEntry, publishToCloud: Bool) throws -> Bool {
        try writer.write { db in
            let id = entry.id.uuidString
            let seen = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tailnet_receipts WHERE entryID = ?) OR EXISTS(SELECT 1 FROM tailnet_journal WHERE entryID = ?)", arguments: [id, id]) ?? false
            try db.execute(sql: "INSERT OR IGNORE INTO tailnet_receipts (entryID) VALUES (?)", arguments: [id])
            guard !seen else { return false }
            try db.execute(sql: """
                INSERT INTO clipboard_entries
                (id, content, contentType, rawData, imagePath, timestamp, copyCount, sourceApp,
                 metadata, contentHash, parentEntryId, isPinned, contentTypeMask, isSynced, cloudSyncAllowed, receivedViaTailnet)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, NULL, 0, ?, 0, ?, 1)
                """, arguments: [id, entry.content, entry.contentType.rawValue, entry.rawData, entry.imagePath,
                                   entry.timestamp, entry.sourceApp, entry.metadata, entry.contentHash,
                                   entry.contentTypeMask, publishToCloud && entry.contentType != .filePath])
            return true
        }
    }
}
