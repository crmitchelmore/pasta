import Foundation
import PastaCore

/// A cursor is meaningful only with the database rows committed alongside it.
/// Legacy UserDefaults checkpoints are deliberately never read or written.
/// Saving a cursor is exclusively part of DatabaseManager.applySyncChanges.
enum SyncChangeTokenStore {
    static func load(from database: DatabaseManager) throws -> Data? {
        try database.loadSyncChangeToken()
    }

    static func reset(in database: DatabaseManager) throws {
        try database.resetSyncChangeToken()
    }
}
