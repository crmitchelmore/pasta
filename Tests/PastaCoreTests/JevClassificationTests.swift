import XCTest
@testable import PastaCore

final class JevClassificationTests: XCTestCase {
    func testConfigurationNeverStoresAPIKeyInDefaults() throws {
        let suiteName = "JevClassificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        JevConfiguration(isEnabled: true, endpoint: "https://example.com", model: "test").save(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "pasta.jev.apiKey"))
        XCTAssertTrue(JevConfiguration.load(defaults: defaults).isEnabled)
    }

    func testReportAgreementRate() {
        let now = Date()
        let rows = [
            JevComparisonRow(id: UUID(), timestamp: now, sourceApp: nil, localCategory: .url, jevCategory: .url, confidence: 0.9, latency: 0.1, error: nil),
            JevComparisonRow(id: UUID(), timestamp: now, sourceApp: nil, localCategory: .text, jevCategory: .prose, confidence: 0.7, latency: 0.2, error: nil)
        ]
        let report = JevComparisonReport(generatedAt: now, total: 2, compared: 2, skipped: 0, failed: 0, rows: rows)

        XCTAssertEqual(report.agreements, 1)
        XCTAssertEqual(report.disagreements, 1)
        XCTAssertEqual(report.agreementRate, 0.5)
    }
}
