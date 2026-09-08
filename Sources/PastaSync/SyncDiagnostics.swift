import CloudKit
import CryptoKit
import Foundation
import PastaCore

/// Report only aggregate metadata. Never include CKError descriptions/userInfo,
/// record identifiers, clipboard text, assets, source apps or raw change tokens.
enum SyncDiagnostics {
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func errorSummary(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled" }
        if let pending = error as? PendingSyncUploadsError { return pending.localizedDescription }
        if let account = error as? SyncManager.AccountError {
            return account == .syncDisabled ? "Sync disabled" : "CloudKit entitlement unavailable"
        }
        if let cloud = error as? CKError {
            var message = "CloudKit \(cloud.code) (\(cloud.errorCode))"
            // Partial errors often hide the actionable code. Keep only distinct
            // codes, never the dictionary's record-ID keys or error descriptions.
            if let partial = cloud.partialErrorsByItemID {
                let codes = Set(partial.values.compactMap { ($0 as? CKError)?.errorCode }).sorted()
                message += "; partial CloudKit codes: \(codes.map(String.init).joined(separator: ", "))"
            }
            if let retry = cloud.retryAfterSeconds, retry.isFinite, retry >= 0, retry < Double(Int.max) {
                message += "; retry after \(Int(retry)) seconds"
            }
            return message
        }
        let ns = error as NSError
        let domain = [NSURLErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain].contains(ns.domain) ? ns.domain : "Other error"
        return "\(domain) (\(ns.code))"
    }

    static func localLines(_ local: SyncLocalSnapshot) -> [String] {
        [
            "Local records: \(local.recordIDs.count)",
            "Local records marked synced: \(local.recordIDs.count - local.pendingCount) (not a cloud count)",
            "Local records pending upload: \(local.pendingCount)",
            "Download checkpoint: \(local.hasCheckpoint ? "present" : "none; next pull starts from the beginning")"
        ]
    }

    static func comparisonLines(local: SyncLocalSnapshot?, cloudIDs: Set<String>) -> [String] {
        var lines = ["Cloud ClipboardEntry records: \(cloudIDs.count) (fresh metadata scan)"]
        if let local {
            lines += [
                "Records on both: \(local.recordIDs.intersection(cloudIDs).count)",
                "Cloud records missing locally: \(cloudIDs.subtracting(local.recordIDs).count)",
                "Local records absent from cloud: \(local.recordIDs.subtracting(cloudIDs).count)",
                "Counts can change during sync. Local-only records are kept; diagnostics do not upload, delete or reset anything."
            ]
        }
        return lines
    }
}

/// A fresh inventory independent of the saved download cursor. desiredKeys=[]
/// asks CloudKit for system metadata only, so no clipboard content/assets move.
final class SyncCloudInventory: @unchecked Sendable {
    private let lock = NSLock()
    private var recordIDs: Set<String> = []
    private var failure: Error?

    func makeOperation(zoneID: CKRecordZone.ID) -> CKFetchRecordZoneChangesOperation {
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = nil
        config.desiredKeys = []
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
        operation.fetchAllChanges = true
        operation.configuration.timeoutIntervalForRequest = 30
        operation.configuration.timeoutIntervalForResource = 90
        operation.qualityOfService = .userInitiated
        operation.recordWasChangedBlock = { [self] id, result in
            lock.withLock {
                switch result {
                case .success(let record):
                    if record.recordType == "ClipboardEntry" { recordIDs.insert(id.recordName.uppercased()) }
                case .failure(let error): if failure == nil { failure = error }
                }
            }
        }
        operation.recordWithIDWasDeletedBlock = { [self] id, _ in
            _ = lock.withLock { recordIDs.remove(id.recordName.uppercased()) }
        }
        operation.recordZoneFetchResultBlock = { [self] _, result in
            if case .failure(let error) = result {
                lock.withLock { if failure == nil { failure = error } }
            }
        }
        return operation
    }

    func result() throws -> Set<String> {
        try lock.withLock {
            if let failure { throw failure }
            return recordIDs
        }
    }
}
