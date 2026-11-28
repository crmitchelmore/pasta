import PastaCore
import PastaDetectors
import XCTest

/// The iOS capture path (`AppState.captureCurrentClipboardIfNeeded`): classify
/// with the shared detectors, apply the secret sync policy, store, then let the
/// sync backfill decide what reaches iCloud.
final class IOSCaptureSyncFlowTests: XCTestCase {
    private let captures: [(content: String, sensitive: Bool)] = [
        ("https://example.com/docs", false),
        ("Lunch at noon tomorrow?", false),
        ("API_KEY=example-value-123", true),
        // Assembled at runtime so no literal token trips secret scanning.
        ("token: " + "gh" + "p_" + "Zq8rT2mXv9KpL4wN7bYc1HdF6gJsQ3aE5uRt" + " is live", true),
        ("4111 1111 1111 1111", true),
    ]

    func testDetectedSecretsStayLocalUnlessTheUserSyncsThem() async throws {
        for syncSecrets in [false, true] {
            let db = try DatabaseManager.inMemory()
            for capture in captures {
                let classified = CapturedTextClassifier.entry(content: capture.content, sourceApp: "iOS Pasteboard")
                XCTAssertEqual(CloudSyncPolicy.containsSensitiveContent(classified), capture.sensitive,
                               "\(capture.content) classified as \(classified.contentType)")
                let entry = CloudSyncPolicy.applying(to: classified, syncSensitiveContent: syncSecrets)
                XCTAssertEqual(entry.allowsCloudUpload, syncSecrets || !capture.sensitive, capture.content)
                try db.insert(entry, deduplicate: false)
            }

            let pending = try db.fetchUnsynced()
            _ = try await db.backfillUnsynced { batch, onBatchSynced in
                onBatchSynced(batch.map(\.id))
                return batch.count
            }
            let queued = pending.map(\.content)
            XCTAssertEqual(try db.unsyncedCount(), 0, "backfill must drain only the upload-eligible rows")
            let expected = captures.filter { syncSecrets || !$0.sensitive }.map(\.content)
            XCTAssertEqual(Set(queued), Set(expected), "syncSecrets=\(syncSecrets)")
            XCTAssertEqual(try db.fetchAll().count, captures.count, "local history keeps every capture")
        }
    }
}
