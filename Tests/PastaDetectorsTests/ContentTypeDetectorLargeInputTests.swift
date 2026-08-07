import XCTest
@testable import PastaDetectors

final class ContentTypeDetectorLargeInputTests: XCTestCase {
    /// Detection clamps its analysis input, so a multi-megabyte paste must not
    /// cost ~15 full-text regex passes. The bound is deliberately generous —
    /// this is a "did we regress to unbounded scanning" guard, not a benchmark.
    func testDetectionOfMultiMegabyteInputCompletesQuickly() {
        let detector = ContentTypeDetector()

        let paragraph = """
        Please contact support@example.com or visit https://example.com/docs for \
        the runbook. Host 10.0.0.14 is failing, request id \
        3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F, see /var/log/pasta/service.log.
        """
        // ~6 MB of realistic, detector-triggering prose.
        let text = String(repeating: paragraph + "\n", count: 30_000)
        XCTAssertGreaterThan(text.utf8.count, 5_000_000)

        let start = Date()
        let output = detector.detect(in: text)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "Detection took \(elapsed)s — analysis input is probably unclamped again")
        XCTAssertNotEqual(output.primaryType, .unknown)
    }

    /// A giant non-base64 blob must not pay for the base64 hypothesis (four
    /// whole-string rewrites plus a whole-string regex).
    func testEncodingDetectorSkipsBase64CheckForHugeInputs() {
        let detector = EncodingDetector()
        // Valid base64 alphabet and length, but far too large to be worth testing.
        let text = String(repeating: "QUJDRA", count: 40_000)
        XCTAssertGreaterThan(text.utf8.count, 200_000)

        let start = Date()
        let detections = detector.detect(in: text)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(detections.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "EncodingDetector took \(elapsed)s on a huge input")
    }

    /// Clamping must not change the answer for ordinary clipboard content.
    func testClampingLeavesShortInputsUntouched() {
        let detector = ContentTypeDetector()

        XCTAssertEqual(detector.detect(in: "user@example.com").primaryType, .email)
        XCTAssertEqual(detector.detect(in: "https://example.com/docs").primaryType, .url)
    }
}
