import CloudKit
import Foundation
import os.log
import PastaCore
import Security

/// Orchestrates CloudKit sync for clipboard entries.
/// Used by both macOS (push) and iOS (pull + push responses).
public final class SyncManager: ObservableObject {
    public enum SyncState: Equatable {
        case idle
        case syncing
        case error(String)
    }
    
    @Published public private(set) var syncState: SyncState = .idle
    @Published public private(set) var lastSyncDate: Date?
    @Published public private(set) var syncedEntryCount: Int = 0
    @Published public private(set) var totalEntriesToSync: Int = 0
    
    private var syncCancelled = false
    
    /// Cancel an in-progress bulk sync.
    public func cancelSync() {
        syncCancelled = true
    }
    
    private var container: CKContainer?
    private var database: CKDatabase?
    private var pullService: SyncPullService?
    @MainActor private var isPullInProgress = false
    private let recordMapper: RecordMapper
    private let logger = Logger(subsystem: "com.pasta.sync", category: "SyncManager")
    private let containerIdentifier: String?
    
    // Zone for custom zone operations
    public static let zoneName = "PastaZone"
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    
    // UserDefaults keys for sync tokens
    private let lastSyncDateKey = "com.pasta.sync.lastSyncDate"
    
    /// Whether sync is enabled. Disabled when CloudKit entitlement is missing.
    public let syncEnabled: Bool
    
    /// - Parameters:
    ///   - containerIdentifier: Explicit CloudKit container ID, or nil to use the default container.
    ///   - syncEnabled: Set false to disable all CloudKit operations.
    public init(containerIdentifier: String? = nil, syncEnabled: Bool = true, pullService: SyncPullService? = nil) {
        self.pullService = pullService
        self.containerIdentifier = containerIdentifier
        self.syncEnabled = syncEnabled
        self.recordMapper = RecordMapper()
        self.lastSyncDate = UserDefaults.standard.object(forKey: lastSyncDateKey) as? Date
    }
    
    /// Resolves the CloudKit container. Returns false if CloudKit is unavailable.
    private func resolveContainer() -> Bool {
        guard syncEnabled else { return false }
        guard container == nil else { return true }
        
        // Check entitlement at runtime to avoid SIGTRAP from CKContainer
        // when the binary lacks CloudKit entitlements.
        guard Self.hasCloudKitEntitlement() else {
            logger.info("CloudKit entitlement not present, sync disabled")
            return false
        }
        
        if let containerIdentifier {
            container = CKContainer(identifier: containerIdentifier)
        } else {
            container = CKContainer.default()
        }
        database = container?.privateCloudDatabase
        return container != nil
    }
    
    /// Checks whether the running binary has the icloud-services entitlement.
    private static func hasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        )
        guard let services = value as? [String] else { return false }
        return services.contains("CloudKit")
        #else
        // App Store builds may not retain a readable embedded provisioning
        // profile after installation. The release lane defines this flag only
        // after validating the profile and signed archive grant our container.
        #if PASTA_IOS_CLOUDKIT_PROVISIONED
        return true
        #else
        return false
        #endif
        #endif
    }
    
    // MARK: - Zone Setup
    
    /// Creates the custom record zone if it doesn't exist.
    public func setupZone() async throws {
        guard resolveContainer(), let database else { return }
        let zone = CKRecordZone(zoneID: Self.zoneID)
        do {
            _ = try await database.save(zone)
            logger.info("Created CloudKit zone: \(Self.zoneName)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            logger.info("Zone already exists")
        } catch {
            logger.error("Failed to create zone: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Push (Mac → CloudKit)
    
    /// Pushes a single entry to CloudKit.
    ///
    /// Throws (leaving the entry unsynced, so `fetchUnsynced` retries it
    /// later) when the record's temporary asset file cannot be written.
    public func pushEntry(_ entry: ClipboardEntry) async throws {
        // Callers mark the entry synced on success. An unavailable transport
        // must fail so the local row remains queued for a later upload.
        guard resolveContainer(), let database else { throw CKError(.notAuthenticated) }
        let prepared: RecordMapper.PreparedRecord
        do {
            prepared = try recordMapper.preparedRecord(from: entry, zoneID: Self.zoneID)
        } catch {
            logger.error("Failed to stage asset for entry \(entry.id.uuidString): \(error.localizedDescription) — leaving unsynced for retry")
            throw error
        }
        defer { prepared.cleanupTemporaryAsset() }
        do {
            _ = try await database.save(prepared.record)
            logger.debug("Pushed entry \(entry.id.uuidString)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            logger.info("Entry \(entry.id.uuidString) already exists with newer version, skipping")
        } catch {
            logger.error("Failed to push entry: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Pushes multiple entries to CloudKit in batches.
    /// Returns the number of entries successfully pushed.
    /// The `onBatchSynced` callback receives the IDs of each successfully pushed batch.
    @discardableResult
    public func pushEntries(
        _ entries: [ClipboardEntry],
        batchSize: Int = 200,
        onBatchSynced: (([UUID]) -> Void)? = nil
    ) async throws -> Int {
        guard resolveContainer(), let database else { throw CKError(.notAuthenticated) }
        syncCancelled = false
        await MainActor.run {
            syncState = .syncing
            syncedEntryCount = 0
            totalEntriesToSync = entries.count
        }
        do {

            let batches = stride(from: 0, to: entries.count, by: batchSize).map {
                Array(entries[$0..<min($0 + batchSize, entries.count)])
            }
        
            var totalPushed = 0
            for (index, batch) in batches.enumerated() {
                if syncCancelled {
                    let cancelledAt = totalPushed
                    logger.info("Sync cancelled by user after \(cancelledAt)/\(entries.count) entries")
                    break
                }
            
                // An entry whose temp asset can't be written is EXCLUDED from the
                // batch (and from onBatchSynced below), so it stays unsynced and
                // is retried later, rather than being pushed asset-less and then
                // marked synced — that would silently lose the image bytes on
                // every other device.
                var includedEntries: [ClipboardEntry] = []
                var prepared: [RecordMapper.PreparedRecord] = []
                includedEntries.reserveCapacity(batch.count)
                prepared.reserveCapacity(batch.count)
                for entry in batch {
                    do {
                        prepared.append(try recordMapper.preparedRecord(from: entry, zoneID: Self.zoneID))
                        includedEntries.append(entry)
                    } catch {
                        logger.error("Failed to stage asset for entry \(entry.id.uuidString): \(error.localizedDescription) — leaving unsynced for retry")
                    }
                }
                // The temp asset files must survive until CloudKit has finished
                // uploading this batch; remove them when the iteration ends
                // (normal completion, throw, or cancellation break).
                defer {
                    for record in prepared { record.cleanupTemporaryAsset() }
                }
                if includedEntries.isEmpty {
                    totalPushed = min((index + 1) * batchSize, entries.count)
                    continue
                }
                let operation = CKModifyRecordsOperation(recordsToSave: prepared.map(\.record))
                operation.savePolicy = .changedKeys
                operation.qualityOfService = .utility
            
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    operation.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success:
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                    database.add(operation)
                }
            
                totalPushed = min((index + 1) * batchSize, entries.count)
                let pushed = totalPushed
                let batchIDs = includedEntries.map { $0.id }
                onBatchSynced?(batchIDs)
                await MainActor.run {
                    syncedEntryCount = pushed
                }
                logger.info("Pushed batch of \(batch.count) entries (\(pushed)/\(entries.count))")
            }
        
            await MainActor.run {
                lastSyncDate = Date()
                UserDefaults.standard.set(lastSyncDate, forKey: lastSyncDateKey)
            }
            await MainActor.run {
                syncState = .idle
                totalEntriesToSync = 0
            }
            return totalPushed
        } catch {
            await MainActor.run {
                syncState = .error(error.localizedDescription)
                totalEntriesToSync = 0
            }
            throw error
        }
    }
    
    /// Deletes an entry from CloudKit.
    public func deleteEntry(id: UUID) async throws {
        guard resolveContainer(), let database else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: Self.zoneID)
        try await database.deleteRecord(withID: recordID)
        logger.debug("Deleted entry \(id.uuidString) from CloudKit")
    }
    
    // MARK: - Pull (CloudKit → local)
    
    /// Downloads and durably applies changes before advancing the token.
    /// Both apps must use this operation; raw fetch results are never exposed
    /// to callers that could accidentally discard them.
    @MainActor
    public func pullChanges(into localDatabase: DatabaseManager) async throws {
        guard !isPullInProgress else { throw SyncPullService.PullError.alreadyInProgress }
        isPullInProgress = true
        defer { isPullInProgress = false }
        syncState = .syncing
        do {
            if pullService == nil {
                guard resolveContainer(), let database else {
                    throw CKError(.notAuthenticated)
                }
                let mapper = recordMapper
                pullService = SyncPullService(
                    fetch: { tokenData in
                        return try await Self.fetchUncommittedChanges(
                            from: database, mapper: mapper, previousTokenData: tokenData
                        )
                    }
                )
            }
            guard let pullService else { throw CKError(.internalError) }
            let batch = try await pullService.pull(into: localDatabase)
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: lastSyncDateKey)
            syncedEntryCount += batch.modified.count
            syncState = .idle
        } catch {
            syncState = .error(error.localizedDescription)
            throw error
        }
    }

    private static func fetchUncommittedChanges(
        from database: CKDatabase,
        mapper: RecordMapper,
        previousTokenData: Data?
    ) async throws -> SyncChangeBatch {
        let savedToken = try previousTokenData.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        let changes = PendingCloudChanges()
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = savedToken
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [Self.zoneID],
            configurationsByRecordZoneID: [Self.zoneID: configuration]
        )
        operation.fetchAllChanges = true
        operation.recordWasChangedBlock = { _, result in
            switch result {
            case .success(let record):
                switch Self.disposition(for: record, mapper: mapper) {
                case .apply(let entry):
                    changes.modify(entry)
                case .assetUnavailable:
                    // An unreadable asset must fail the batch. Otherwise the
                    // token would skip image bytes that never reached SQLite.
                    changes.fail(CKError(.assetFileNotFound))
                case .unmappable(let reason):
                    // Never fail the batch for a record this build cannot
                    // represent (e.g. a contentType introduced by a newer app
                    // on another device): it would be refetched and fail on
                    // every later pull, freezing sync until the app updates.
                    changes.skipUnmappable()
                    Self.pullLogger.warning("Skipping remote record \(record.recordID.recordName): \(reason)")
                }
            case .failure(let error):
                changes.fail(error)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            guard let id = UUID(uuidString: recordID.recordName) else {
                changes.fail(CKError(.internalError))
                return
            }
            changes.delete(id)
        }
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let (token, _, _)):
                changes.setToken(token)
            case .failure(let error):
                changes.fail(error)
            }
        }
        operation.qualityOfService = .utility
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.fetchRecordZoneChangesResultBlock = { result in
                    continuation.resume(with: result)
                }
                database.add(operation)
                if Task.isCancelled { operation.cancel() }
            }
        } onCancel: {
            operation.cancel()
        }
        let skipped = changes.skippedUnmappableCount
        if skipped > 0 {
            Self.pullLogger.warning("Pull skipped \(skipped) remote record(s) this app version cannot represent; update the app to receive them")
        }
        return try changes.batch()
    }

    /// The pull runs in a static context (no instance), so it logs through this.
    private static let pullLogger = Logger(subsystem: "com.pasta.sync", category: "SyncPull")

    /// How `pullChanges` treats one fetched record. A pure function so the
    /// decision is unit-testable without CloudKit.
    enum RemoteRecordDisposition: Equatable {
        /// Persist this entry.
        case apply(ClipboardEntry)
        /// The record carries an image asset whose bytes could not be read.
        /// Transient: the batch must fail so the token does not move past it.
        case assetUnavailable
        /// This build cannot represent the record (unknown `contentType`,
        /// malformed id, missing required fields). Permanent for this build,
        /// so it is skipped rather than allowed to poison every later pull.
        case unmappable(reason: String)
    }

    static func disposition(for record: CKRecord, mapper: RecordMapper) -> RemoteRecordDisposition {
        if let entry = mapper.entry(from: record) {
            if record["imageAsset"] is CKAsset, entry.rawData == nil {
                return .assetUnavailable
            }
            return .apply(entry)
        }
        if UUID(uuidString: record.recordID.recordName) == nil {
            return .unmappable(reason: "record name is not a UUID")
        }
        guard let contentTypeRaw = record["contentType"] as? String else {
            return .unmappable(reason: "missing contentType")
        }
        if ContentType(rawValue: contentTypeRaw) == nil {
            return .unmappable(reason: "unknown contentType '\(contentTypeRaw)'")
        }
        if record["content"] as? String == nil {
            return .unmappable(reason: "missing content")
        }
        if record["timestamp"] as? Date == nil {
            return .unmappable(reason: "missing timestamp")
        }
        return .unmappable(reason: "record could not be mapped")
    }

    // MARK: - Subscriptions
    
    /// Registers for push notifications on record changes.
    public func registerSubscription() async throws {
        guard resolveContainer(), let database else { return }
        let subscriptionID = "pasta-clipboard-changes"
        
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        
        do {
            _ = try await database.save(subscription)
            logger.info("Registered CloudKit subscription")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            logger.info("Subscription already exists")
        }
    }
    
    // MARK: - Account Status
    
    /// Checks if iCloud is available.
    public func checkAccountStatus() async throws -> CKAccountStatus {
        guard resolveContainer(), let container else { return .couldNotDetermine }
        return try await container.accountStatus()
    }
    
    // MARK: - Token Persistence
    
    /// Resets the sync state (clears token, forces full re-sync).
    @MainActor
    public func resetSync(in localDatabase: DatabaseManager) throws {
        guard !isPullInProgress, syncState != .syncing else { return }
        try SyncChangeTokenStore.reset(in: localDatabase)
        UserDefaults.standard.removeObject(forKey: lastSyncDateKey)
        syncedEntryCount = 0
        lastSyncDate = nil
        logger.info("Sync state reset")
    }
}

/// CloudKit callbacks may use different queues; keep the batch and first
/// error together and never acknowledge a partially decoded response.
private final class PendingCloudChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var modified: [UUID: ClipboardEntry] = [:]
    private var deleted: Set<UUID> = []
    private var token: CKServerChangeToken?
    private var error: Error?
    private var skippedUnmappable = 0

    /// Records this build cannot represent are counted and left out of the
    /// batch; the token still advances past them (see `RemoteRecordDisposition`).
    func skipUnmappable() {
        lock.lock(); defer { lock.unlock() }
        skippedUnmappable += 1
    }

    var skippedUnmappableCount: Int {
        lock.lock(); defer { lock.unlock() }
        return skippedUnmappable
    }

    func modify(_ entry: ClipboardEntry) {
        lock.lock(); defer { lock.unlock() }
        modified[entry.id] = entry
        deleted.remove(entry.id)
    }

    func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        modified.removeValue(forKey: id)
        deleted.insert(id)
    }

    func setToken(_ token: CKServerChangeToken) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if self.error == nil { self.error = error }
    }

    func batch() throws -> SyncChangeBatch {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard let token else { throw CKError(.internalError) }
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        return SyncChangeBatch(modified: Array(modified.values), deleted: Array(deleted), token: data)
    }
}
