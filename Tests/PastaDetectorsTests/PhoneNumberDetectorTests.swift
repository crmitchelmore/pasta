import XCTest
@testable import PastaDetectors

final class PhoneNumberDetectorTests: XCTestCase {
    func testMediumProfileRejectsLongUnformattedNumericBlobs() {
        let detector = PhoneNumberDetector()
        let text = "Order IDs: 202602191651 19105072027582 35938854136 8589934595"

        let detections = detector.detect(in: text, strictness: .medium)
        XCTAssertTrue(detections.isEmpty)
    }

    func testLaxProfileAllowsUnformattedNumbers() {
        let detector = PhoneNumberDetector()
        let text = "Order IDs: 202602191651 19105072027582"

        let detections = detector.detect(in: text, strictness: .lax)
        XCTAssertEqual(detections.count, 2)
    }

    func testStrictProfileRequiresConventionalFormatting() {
        let detector = PhoneNumberDetector()
        let text = "Call +1 415-555-0199 or (020) 7123 4567"

        let detections = detector.detect(in: text, strictness: .strict)
        XCTAssertEqual(detections.count, 2)
    }

    func testAdvancedPatternsOverrideBuiltInRules() {
        let detector = PhoneNumberDetector()
        let text = "Internal extension ext-90210 is active"

        let detections = detector.detect(
            in: text,
            strictness: .strict,
            advancedPatterns: [#"ext-(\d{5})"#]
        )

        XCTAssertEqual(detections.map(\.phoneNumber), ["90210"])
    }
}
