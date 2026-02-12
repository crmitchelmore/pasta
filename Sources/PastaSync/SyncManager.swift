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
    private let recordMapper: RecordMapper
    private let logger = Logger(subsystem: "com.pasta.sync", category: "SyncManager")
    private let containerIdentifier: String?
    
    // Zone for custom zone operations
    public static let zoneName = "PastaZone"
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    
    // UserDefaults keys for sync tokens
    private let changeTokenKey = "com.pasta.sync.changeToken"
    
    /// Whether sync is enabled. Disabled when CloudKit entitlement is missing.
    public let syncEnabled: Bool
    
    /// - Parameters:
    ///   - containerIdentifier: Explicit CloudKit container ID, or nil to use the default container.
    ///   - syncEnabled: Set false to disable all CloudKit operations.
    public init(containerIdentifier: String? = nil, syncEnabled: Bool = true) {
        self.containerIdentifier = containerIdentifier
        self.syncEnabled = syncEnabled
        self.recordMapper = RecordMapper()
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
        return value != nil
        #else
        // iOS always has entitlements when properly provisioned
        return true
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
    public func pushEntry(_ entry: ClipboardEntry) async throws {
        guard resolveContainer(), let database else { return }
        let record = recordMapper.record(from: entry, zoneID: Self.zoneID)
        do {
            _ = try await database.save(record)
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
    @discardableResult
    public func pushEntries(_ entries: [ClipboardEntry], batchSize: Int = 200) async throws -> Int {
        guard resolveContainer(), let database else { return 0 }
        syncCancelled = false
        await MainActor.run {
            syncState = .syncing
            syncedEntryCount = 0
            totalEntriesToSync = entries.count
        }
        defer {
            Task { @MainActor in
                syncState = .idle
                totalEntriesToSync = 0
            }
        }
        
        let batches = stride(from: 0, to: entries.count, by: batchSize).map {
            Array(entries[$0..<min($0 + batchSize, entries.count)])
        }
        
        var totalPushed = 0
        for (index, batch) in batches.enumerated() {
            if syncCancelled {
                logger.info("Sync cancelled by user after \(totalPushed)/\(entries.count) entries")
                break
            }
            
            let records = batch.map { recordMapper.record(from: $0, zoneID: Self.zoneID) }
            let operation = CKModifyRecordsOperation(recordsToSave: records)
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
            await MainActor.run {
                syncedEntryCount = totalPushed
            }
            logger.info("Pushed batch of \(batch.count) entries (\(totalPushed)/\(entries.count))")
        }
        
        await MainActor.run { lastSyncDate = Date() }
        return totalPushed
    }
    
    /// Deletes an entry from CloudKit.
    public func deleteEntry(id: UUID) async throws {
        guard resolveContainer(), let database else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: Self.zoneID)
        try await database.deleteRecord(withID: recordID)
        logger.debug("Deleted entry \(id.uuidString) from CloudKit")
    }
    
    // MARK: - Pull (CloudKit → local)
    
    /// Fetches all changes since the last sync token.
    /// Returns new/modified entries and deleted entry IDs.
    public func fetchChanges() async throws -> (modified: [ClipboardEntry], deleted: [UUID]) {
        guard resolveContainer(), let database else { return ([], []) }
        await MainActor.run { syncState = .syncing }
        defer { Task { @MainActor in syncState = .idle } }
        
        let savedToken = loadChangeToken()
        
        var modifiedEntries: [ClipboardEntry] = []
        var deletedIDs: [UUID] = []
        var newToken: CKServerChangeToken?
        
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = savedToken
        
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [Self.zoneID],
            configurationsByRecordZoneID: [Self.zoneID: configuration]
        )
        
        operation.recordWasChangedBlock = { [recordMapper] _, result in
            switch result {
            case .success(let record):
                if let entry = recordMapper.entry(from: record) {
                    modifiedEntries.append(entry)
                }
            case .failure(let error):
                self.logger.error("Failed to process changed record: \(error.localizedDescription)")
            }
        }
        
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            if let uuid = UUID(uuidString: recordID.recordName) {
                deletedIDs.append(uuid)
            }
        }
        
        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            newToken = token
        }
        
        operation.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let (serverChangeToken, _, _)):
                newToken = serverChangeToken
            case .failure(let error):
                self.logger.error("Zone fetch failed: \(error.localizedDescription)")
            }
        }
        
        operation.qualityOfService = .userInitiated
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
        
        if let token = newToken {
            saveChangeToken(token)
        }
        
        let modifiedCount = modifiedEntries.count
        await MainActor.run {
            lastSyncDate = Date()
            syncedEntryCount += modifiedCount
        }
        
        logger.info("Fetched \(modifiedCount) modified, \(deletedIDs.count) deleted")
        return (modifiedEntries, deletedIDs)
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
    
    private func saveChangeToken(_ token: CKServerChangeToken) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: changeTokenKey)
        } catch {
            logger.error("Failed to save change token: \(error.localizedDescription)")
        }
    }
    
    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
    
    /// Resets the sync state (clears token, forces full re-sync).
    public func resetSync() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
        Task { @MainActor in
            syncedEntryCount = 0
            lastSyncDate = nil
        }
        logger.info("Sync state reset")
    }
}
