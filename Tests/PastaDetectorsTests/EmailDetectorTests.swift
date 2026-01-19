import XCTest
@testable import PastaDetectors

final class EmailDetectorTests: XCTestCase {
    func testDetectSingleEmail() {
        let detector = EmailDetector()
        let results = detector.detect(in: "Contact me at test@example.com.")
        XCTAssertEqual(results.map(\.email), ["test@example.com"])
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.9)
    }

    func testDetectMultipleEmailsDedupes() {
        let detector = EmailDetector()
        let results = detector.detect(in: "A a@example.com B A@EXAMPLE.COM C b@example.co.uk")
        XCTAssertEqual(results.map(\.email), ["a@example.com", "b@example.co.uk"])
    }

    func testRejectInvalidEmails() {
        let detector = EmailDetector()
        let text = "bad@ example.com also bad@@example.com and @example.com and a@b"
        XCTAssertTrue(detector.detect(in: text).isEmpty)
    }

    func testDetectEmailAtStringBounds() {
        let detector = EmailDetector()
        let results = detector.detect(in: "xxa@example.comyy")
        XCTAssertEqual(results.map(\.email), ["xxa@example.comyy"])
    }
}
