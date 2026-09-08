import CloudKit
import Foundation
import PastaCore
import XCTest
@testable import PastaSync

final class SyncDiagnosticsTests: XCTestCase {
    func testAccountFingerprintIsStableAndDoesNotExposeTheAccountIdentifier() {
        let accountID = "_private_account_identifier_diagnostics_canary"
        let fingerprint = SyncDiagnostics.fingerprint(accountID)

        XCTAssertEqual(fingerprint, SyncDiagnostics.fingerprint(accountID))
        XCTAssertNotEqual(fingerprint, SyncDiagnostics.fingerprint(accountID + "_another"))
        XCTAssertEqual(fingerprint.count, 24)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit })
        XCTAssertFalse(fingerprint.contains(accountID))
    }

    func testErrorSummaryKeepsActionableCodesWithoutDescriptionsOrPartialRecordIDs() {
        let privateRecordID = "private-record-name-diagnostics-canary"
        let privateDescription = "private-clipboard-and-account-details-diagnostics-canary"
        let partialError = CKError(.permissionFailure, userInfo: [
            NSLocalizedDescriptionKey: privateDescription,
            NSDebugDescriptionErrorKey: privateDescription
        ])
        let error = CKError(.partialFailure, userInfo: [
            NSLocalizedDescriptionKey: privateDescription,
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: privateRecordID): partialError],
            CKErrorRetryAfterKey: 12.0
        ])

        let summary = SyncDiagnostics.errorSummary(error)

        XCTAssertTrue(summary.contains("CloudKit"))
        XCTAssertTrue(summary.contains("(\(CKError.Code.partialFailure.rawValue))"))
        XCTAssertTrue(summary.contains("partial CloudKit codes: \(CKError.Code.permissionFailure.rawValue)"))
        XCTAssertTrue(summary.contains("retry after 12 seconds"))
        XCTAssertFalse(summary.contains(privateRecordID))
        XCTAssertFalse(summary.contains(privateDescription))
    }

    func testUnknownErrorDomainAndDescriptionAreNotPrinted() {
        let error = NSError(
            domain: "private-clipboard-domain-diagnostics-canary",
            code: 27,
            userInfo: [NSLocalizedDescriptionKey: "private-description-diagnostics-canary"]
        )

        XCTAssertEqual(SyncDiagnostics.errorSummary(error), "Other error (27)")
        XCTAssertEqual(SyncDiagnostics.errorSummary(CancellationError()), "Cancelled")
        XCTAssertEqual(SyncDiagnostics.errorSummary(SyncManager.AccountError.syncDisabled), "Sync disabled")
    }

    @MainActor
    func testDisabledDiagnosticReportPreservesHistoryPendingMarkersAndCheckpointWithoutLeakingContents() async throws {
        let database = try DatabaseManager.inMemory()
        let pending = ClipboardEntry(
            content: "private-pending-clipboard-diagnostics-canary",
            contentType: .text,
            rawData: Data("private-raw-data-diagnostics-canary".utf8),
            sourceApp: "private-source-app-diagnostics-canary",
            isPinned: true
        )
        let synced = ClipboardEntry(
            content: "private-synced-clipboard-diagnostics-canary",
            contentType: .text,
            isSynced: true
        )
        let checkpoint = Data("private-change-token-diagnostics-canary".utf8)
        try database.insertBatch([pending, synced])
        try database.applySyncChanges(modified: [], deleted: [], checkpoint: checkpoint)
        let pendingBefore = try database.fetch(id: pending.id)
        let syncedBefore = try database.fetch(id: synced.id)
        let manager = SyncManager(containerIdentifier: "iCloud.com.pasta.ios", syncEnabled: false)
        let previousLastSync = manager.lastSyncDate

        let report = await manager.diagnosticReport(localDatabase: database)

        XCTAssertTrue(report.contains("Local records: 2"))
        XCTAssertTrue(report.contains("Local records marked synced: 1 (not a cloud count)"))
        XCTAssertTrue(report.contains("Local records pending upload: 1"))
        XCTAssertTrue(report.contains("Download checkpoint: present"))
        XCTAssertTrue(report.contains("Cloud inventory failed: Sync disabled"))
        XCTAssertFalse(report.contains("Cloud ClipboardEntry records: 0"), "Unavailable cloud access must never look like an empty server")
        for privateValue in [pending.content, synced.content, pending.sourceApp!, pending.id.uuidString,
                             synced.id.uuidString, "private-raw-data-diagnostics-canary",
                             "private-change-token-diagnostics-canary", checkpoint.base64EncodedString()] {
            XCTAssertFalse(report.contains(privateValue), "Diagnostics exposed a private value")
        }
        XCTAssertEqual(try database.countEntries(), 2)
        XCTAssertEqual(try database.fetch(id: pending.id), pendingBefore)
        XCTAssertEqual(try database.fetch(id: synced.id), syncedBefore)
        XCTAssertEqual(try database.fetchUnsynced().map(\.id), [pending.id])
        XCTAssertEqual(try database.loadSyncChangeToken(), checkpoint)
        XCTAssertEqual(manager.lastSyncDate, previousLastSync)
        XCTAssertEqual(manager.syncState, .idle)
    }

    func testMembershipComparisonPrintsOnlyAggregateCounts() throws {
        let database = try DatabaseManager.inMemory()
        let shared = ClipboardEntry(content: "private-shared-diagnostics-canary", contentType: .text, isSynced: true)
        let localOnly = ClipboardEntry(content: "private-local-only-diagnostics-canary", contentType: .text)
        let cloudOnly = UUID().uuidString
        try database.insertBatch([shared, localOnly])
        let snapshot = try database.syncDiagnosticSnapshot()

        let report = SyncDiagnostics.comparisonLines(
            local: snapshot,
            cloudIDs: [shared.id.uuidString, cloudOnly]
        ).joined(separator: "\n")

        XCTAssertTrue(report.contains("Cloud ClipboardEntry records: 2"))
        XCTAssertTrue(report.contains("Records on both: 1"))
        XCTAssertTrue(report.contains("Cloud records missing locally: 1"))
        XCTAssertTrue(report.contains("Local records absent from cloud: 1"))
        for privateValue in [shared.id.uuidString, localOnly.id.uuidString, cloudOnly, shared.content, localOnly.content] {
            XCTAssertFalse(report.contains(privateValue))
        }
        XCTAssertEqual(snapshot.pendingCount, 1)
        XCTAssertFalse(snapshot.hasCheckpoint)
    }

    func testInventoryStartsFreshAndRequestsNoClipboardFieldsOrAssets() throws {
        let inventory = SyncCloudInventory()
        let zoneID = CKRecordZone.ID(zoneName: "DiagnosticsTestZone", ownerName: CKCurrentUserDefaultName)
        let operation = inventory.makeOperation(zoneID: zoneID)
        let configuration = try XCTUnwrap(operation.configurationsByRecordZoneID?[zoneID])

        XCTAssertEqual(operation.recordZoneIDs, [zoneID])
        XCTAssertNil(configuration.previousServerChangeToken)
        XCTAssertEqual(configuration.desiredKeys, [], "nil would fetch all clipboard content and assets")
        XCTAssertTrue(operation.fetchAllChanges, "A large library must not be reported as only its first page")
        XCTAssertNil(operation.recordZoneChangeTokensUpdatedBlock, "A diagnostic inventory must never persist a download cursor")
    }

    func testInventoryAggregatesClipboardMembershipAndAppliesDeletionWithoutCountingOtherTypes() throws {
        let inventory = SyncCloudInventory()
        let zoneID = CKRecordZone.ID(zoneName: "DiagnosticsTestZone", ownerName: CKCurrentUserDefaultName)
        let operation = inventory.makeOperation(zoneID: zoneID)
        let sharedID = UUID().uuidString
        let deletedID = UUID().uuidString
        let shared = CKRecord(recordType: "ClipboardEntry", recordID: CKRecord.ID(recordName: sharedID.lowercased(), zoneID: zoneID))
        shared["content"] = "private-record-content-diagnostics-canary" as CKRecordValue
        let duplicate = CKRecord(recordType: "ClipboardEntry", recordID: CKRecord.ID(recordName: sharedID, zoneID: zoneID))
        let deleted = CKRecord(recordType: "ClipboardEntry", recordID: CKRecord.ID(recordName: deletedID, zoneID: zoneID))
        let other = CKRecord(recordType: "FutureUnrelatedRecord", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))

        for record in [shared, duplicate, deleted, other] {
            operation.recordWasChangedBlock?(record.recordID, .success(record))
        }
        operation.recordWithIDWasDeletedBlock?(deleted.recordID, deleted.recordType)

        XCTAssertEqual(try inventory.result(), [sharedID])
        let report = SyncDiagnostics.comparisonLines(local: nil, cloudIDs: try inventory.result()).joined(separator: "\n")
        XCTAssertTrue(report.contains("Cloud ClipboardEntry records: 1"))
        XCTAssertFalse(report.contains(sharedID))
        XCTAssertFalse(report.contains("private-record-content-diagnostics-canary"))
    }

    func testPerRecordInventoryFailureCannotProduceAnEmptyOrPartialCloudCount() throws {
        let inventory = SyncCloudInventory()
        let operation = inventory.makeOperation(zoneID: SyncManager.zoneID)
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: SyncManager.zoneID)
        operation.recordWasChangedBlock?(recordID, .failure(CKError(.networkFailure)))

        XCTAssertThrowsError(try inventory.result()) { error in
            XCTAssertEqual((error as? CKError)?.code, .networkFailure)
        }
    }

    func testPerZoneInventoryFailureCannotProduceAnEmptyOrPartialCloudCount() throws {
        let inventory = SyncCloudInventory()
        let operation = inventory.makeOperation(zoneID: SyncManager.zoneID)
        let record = CKRecord(recordType: "ClipboardEntry", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: SyncManager.zoneID))
        operation.recordWasChangedBlock?(record.recordID, .success(record))
        operation.recordZoneFetchResultBlock?(SyncManager.zoneID, .failure(CKError(.zoneNotFound)))

        XCTAssertThrowsError(try inventory.result()) { error in
            XCTAssertEqual((error as? CKError)?.code, .zoneNotFound)
        }
    }
}
