import CloudKit
import XCTest
@testable import PastaSync

final class SingleRecordSaveOutcomeTests: XCTestCase {
    func testRecordConflictSurvivesPartialFailureWrapping() {
        let outcome = SingleRecordSaveOutcome()
        outcome.recordSaved(.failure(CKError(.serverRecordChanged)))
        XCTAssertThrowsError(try outcome.completed(.failure(CKError(.partialFailure))).get()) {
            XCTAssertEqual(($0 as? CKError)?.code, .serverRecordChanged)
        }
    }

    func testOperationSuccessCannotAcknowledgeRecordFailureOrMissingConfirmation() {
        let failed = SingleRecordSaveOutcome()
        failed.recordSaved(.failure(CKError(.quotaExceeded)))
        XCTAssertThrowsError(try failed.completed(.success(())).get()) {
            XCTAssertEqual(($0 as? CKError)?.code, .quotaExceeded)
        }
        XCTAssertThrowsError(try SingleRecordSaveOutcome().completed(.success(())).get())
    }

    func testAcknowledgesConfirmedRecordOnlyAfterOperationSucceeds() throws {
        let outcome = SingleRecordSaveOutcome()
        outcome.recordSaved(.success(CKRecord(recordType: "ClipboardEntry")))
        XCTAssertThrowsError(try outcome.completed(.failure(CKError(.networkFailure))).get())
        try outcome.completed(.success(())).get()
    }
}
