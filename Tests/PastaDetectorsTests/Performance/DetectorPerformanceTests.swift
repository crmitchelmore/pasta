import PastaCore
import XCTest
@testable import PastaDetectors

/// Budgets for the capture path: every copy runs the full detector pipeline.
final class DetectorPerformanceTests: XCTestCase {
    /// Detection clamps its analysis input, so multi-megabyte pastes must not cost
    /// ~15 full-text regex passes. Bounds are loose for `swift test --parallel` on CI;
    /// unclamped regressions take far longer, so they still fire.
    func testLargeInputsStayWithinBudget() {
        let paragraph = """
        Please contact support@example.com or visit https://example.com/docs for \
        the runbook. Host 10.0.0.14 is failing, request id \
        3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F, see /var/log/pasta/service.log.
        """
        let text = String(repeating: paragraph + "\n", count: 30_000)
        XCTAssertGreaterThan(text.utf8.count, 5_000_000)
        var start = Date()
        let output = ContentTypeDetector().detect(in: text)
        var elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "Detection took \(elapsed)s — analysis input is probably unclamped again")
        XCTAssertNotEqual(output.primaryType, .unknown)

        // A giant base64-alphabet blob must not pay for whole-string base64 rewrites.
        let blob = String(repeating: "QUJDRA", count: 40_000)
        start = Date()
        let detections = EncodingDetector().detect(in: blob)
        elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(detections.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "EncodingDetector took \(elapsed)s on a huge input")
    }

    /// Benchmark for typical clipboard shapes; compare `measure` output before and after detector changes.
    func testTypicalClipboardDetectionThroughput() {
        let detector = ContentTypeDetector()
        let fakeKey = ["sk", "test"].joined(separator: "_") + "_" + String(repeating: "0", count: 32)
        let envBlock = [
            "export DATABASE_URL=postgres://user:pass@localhost:5432/db",
            "export REDIS_URL=redis://localhost:6379",
            "export API_KEY=\(fakeKey)",
            "export NODE_ENV=production",
        ].joined(separator: "\n")
        let code = """
        func compute(_ items: [Int]) -> Int {
            var total = 0
            for item in items where item > 0 { total += item * 2 }
            return total
        }
        print("result=\\(compute([1, 2, 3]))")
        """
        let prose = Array(repeating: """
        Lorem ipsum dolor sit amet. Reach out at alice@example.com or visit \
        https://example.com/docs. The ticket id is 550e8400-e29b-41d4-a716-446655440000 \
        and the server runs at 10.0.0.42. Ut enim ad minim veniam, quis nostrud exercitation.
        """, count: 6).joined(separator: "\n\n")
        let samples: [(input: String, repetitions: Int)] = [
            ("Check out https://github.com/example/repo", 50),
            (DetectorTestSupport.makeJWT(header: #"{"alg":"HS256","typ":"JWT"}"#,
                                         payload: #"{"sub":"benchmark","iat":1516239022}"#,
                                         signature: String(repeating: "abcDEF123", count: 5)), 50),
            (envBlock, 50), (code, 50), (prose, 5),
        ]
        measure {
            for sample in samples {
                for _ in 0..<sample.repetitions { _ = detector.detect(in: sample.input) }
            }
        }
    }
}
