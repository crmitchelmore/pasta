import CloudKit
import Foundation

/// CKModifyRecordsOperation may wrap a record error in partialFailure. Keep
/// the single-record save behavior (including serverRecordChanged) intact.
final class SingleRecordSaveOutcome {
    private let lock = NSLock()
    private var recordResult: Result<CKRecord, Error>?

    func recordSaved(_ result: Result<CKRecord, Error>) {
        lock.withLock { recordResult = result }
    }

    func completed(_ operationResult: Result<Void, Error>) -> Result<Void, Error> {
        lock.withLock {
            switch recordResult {
            case .some(.failure(let error)): return .failure(error)
            case .some(.success): return operationResult
            case nil:
                if case .failure = operationResult { return operationResult }
                // Never acknowledge a save with no per-record confirmation.
                return .failure(CKError(.internalError))
            }
        }
    }
}
