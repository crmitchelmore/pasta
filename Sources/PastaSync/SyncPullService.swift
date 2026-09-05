import Foundation
import PastaCore

/// A downloaded batch whose token has not yet been acknowledged.
public struct SyncChangeBatch: Sendable {
    public let modified: [ClipboardEntry]
    public let deleted: [UUID]
    public let token: Data?

    public init(modified: [ClipboardEntry], deleted: [UUID], token: Data?) {
        self.modified = modified
        self.deleted = deleted
        self.token = token
    }
}

/// Shared by both apps. The only substituted dependency in journey tests is
/// the remote transport; persistence uses the real database transaction.
public actor SyncPullService {
    public enum PullError: Error { case alreadyInProgress }
    private let fetch: @Sendable (Data?) async throws -> SyncChangeBatch
    private let acknowledge: @Sendable (Data) async throws -> Void
    private var isPulling = false

    public init(
        fetch: @escaping @Sendable (Data?) async throws -> SyncChangeBatch,
        acknowledge: @escaping @Sendable (Data) async throws -> Void = { _ in }
    ) {
        self.fetch = fetch
        self.acknowledge = acknowledge
    }

    @discardableResult
    public func pull(into database: DatabaseManager) async throws -> SyncChangeBatch {
        // Actors are reentrant across await. Reject overlapping pulls so an
        // older response can never overwrite newer rows or regress the token.
        guard !isPulling else { throw PullError.alreadyInProgress }
        isPulling = true
        defer { isPulling = false }

        try Task.checkCancellation()
        let checkpoint = try await Task.detached(priority: .utility) {
            try SyncChangeTokenStore.load(from: database)
        }.value
        try Task.checkCancellation()
        let batch = try await fetch(checkpoint)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try database.applySyncChanges(modified: batch.modified, deleted: batch.deleted, checkpoint: batch.token)
        }.value
        try Task.checkCancellation()
        // The database already owns its committed cursor. This optional
        // transport notification never persists a separate local checkpoint.
        // A notification failure cannot lose rows or regress the DB cursor;
        // transports that replay are safe because apply is idempotent by UUID.
        if let token = batch.token {
            try await acknowledge(token)
        }
        return batch
    }
}
