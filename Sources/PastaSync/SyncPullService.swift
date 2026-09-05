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
    private let fetch: @Sendable () async throws -> SyncChangeBatch
    private let acknowledge: @Sendable (Data) async throws -> Void
    private var isPulling = false

    public init(
        fetch: @escaping @Sendable () async throws -> SyncChangeBatch,
        acknowledge: @escaping @Sendable (Data) async throws -> Void
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
        let batch = try await fetch()
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try database.applySyncChanges(modified: batch.modified, deleted: batch.deleted)
        }.value
        try Task.checkCancellation()
        // A crash or acknowledgement failure here causes replay, not data
        // loss. applySyncChanges is idempotent by remote record UUID.
        if let token = batch.token {
            try await acknowledge(token)
        }
        return batch
    }
}
