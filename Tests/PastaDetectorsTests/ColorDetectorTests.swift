import XCTest
@testable import PastaDetectors

final class ColorDetectorTests: XCTestCase {
    private let detector = ColorDetector()

    // MARK: - Hex / rgb / hsl parsing

    private struct ParseCase {
        let input: String
        /// Asserted only when non-nil (some original cases checked channels only).
        var format: ColorDetector.Format? = nil
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        /// Asserted only when non-nil.
        var alpha: Double? = nil
    }

    private static let parseCases: [ParseCase] = [
        // Hex
        ParseCase(input: "#FF8800", format: .hex, red: 0xFF, green: 0x88, blue: 0x00, alpha: 1.0),
        ParseCase(input: "#f80", red: 0xFF, green: 0x88, blue: 0x00),
        ParseCase(input: "#11223380", red: 0x11, green: 0x22, blue: 0x33, alpha: 0x80 / 255.0),
        ParseCase(input: "#1238", red: 0x11, green: 0x22, blue: 0x33, alpha: 0x88 / 255.0),
        // rgb / rgba
        ParseCase(input: "rgb(255, 128, 0)", format: .rgb, red: 255, green: 128, blue: 0),
        ParseCase(input: "rgb(255 128 0)", format: .rgb, red: 255, green: 128, blue: 0),
        ParseCase(input: "rgb(100%, 50%, 0%)", red: 255, green: 128, blue: 0),
        ParseCase(input: "rgba(10, 20, 30, 0.5)", format: .rgba, red: 10, green: 20, blue: 30, alpha: 0.5),
        ParseCase(input: "rgb(255 0 0 / 0.25)", format: .rgba, red: 255, green: 0, blue: 0, alpha: 0.25),
        // hsl / hsla
        ParseCase(input: "hsl(0, 100%, 50%)", format: .hsl, red: 255, green: 0, blue: 0),
        ParseCase(input: "hsl(240, 100%, 50%)", red: 0, green: 0, blue: 255),
        ParseCase(input: "hsl(120 100% 25% / 0.5)", format: .hsla, red: 0, green: 128, blue: 0, alpha: 0.5),
    ]

    func testParsesHexRGBAndHSLForms() {
        for testCase in Self.parseCases {
            let r = detector.detect(in: testCase.input).first
            if let format = testCase.format {
                XCTAssertEqual(r?.format, format, testCase.input)
            }
            XCTAssertEqual(r?.red, testCase.red, testCase.input)
            XCTAssertEqual(r?.green, testCase.green, testCase.input)
            XCTAssertEqual(r?.blue, testCase.blue, testCase.input)
            if let alpha = testCase.alpha {
                XCTAssertEqual(r?.alpha ?? 0, alpha, accuracy: 0.001, testCase.input)
            }
        }
    }

    func testRejectRGBOutOfRange() {
        let r = detector.detect(in: "rgb(300, 0, 0)")
        XCTAssertTrue(r.isEmpty, "Out-of-range channel should not match")
    }

    // MARK: - Named colors

    func testNamedColorWholeStringOnlyDefault() {
        // Default policy = wholeStringOnly: must match the trimmed input as a whole.
        let r = detector.detect(in: "cornflowerblue").first
        XCTAssertEqual(r?.format, .named)
        XCTAssertEqual(r?.red, 100)
        XCTAssertEqual(r?.green, 149)
        XCTAssertEqual(r?.blue, 237)
    }

    func testNamedColorNotInProseByDefault() {
        let r = detector.detect(in: "the sky is blue today")
        XCTAssertTrue(r.isEmpty, "Should not extract named color from prose at default policy")
    }

    func testNamedColorExtractInLaxMode() {
        let r = detector.detect(in: "the red car", namedColorPolicy: .extract)
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.first?.format, .named)
        XCTAssertEqual(r.first?.red, 255)
    }

    // MARK: - Negative cases

    func testRejectInvalidHexLength() {
        XCTAssertTrue(detector.detect(in: "#ZZ").isEmpty)
        XCTAssertTrue(detector.detect(in: "#12345").isEmpty)
    }

    func testHexInIdentifierIsRejected() {
        // "color#FF0000" should not match because of word-boundary lookbehind.
        let r = detector.detect(in: "abc#FF0000")
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - ContentTypeDetector strictness wiring

    func testStrictModeRequiresWholeInputColor() {
        let typeDetector = ContentTypeDetector()
        var config = DetectorConfiguration.default
        var rule = config.rule(for: .color)
        rule.strictnessOverride = .strict
        config.setRule(rule, for: .color)

        let pure = typeDetector.detect(in: "#ff0000", configuration: config)
        XCTAssertEqual(pure.primaryType, .color)

        // Surrounding text should not be classified as color in strict mode.
        let mixed = typeDetector.detect(in: "the value is #ff0000 here", configuration: config)
        XCTAssertNotEqual(mixed.primaryType, .color)
    }

    func testMediumModeDetectsHexAroundShortContext() {
        let typeDetector = ContentTypeDetector()
        var config = DetectorConfiguration.default
        var rule = config.rule(for: .color)
        rule.strictnessOverride = .medium
        config.setRule(rule, for: .color)

        let res = typeDetector.detect(in: "#ff8800", configuration: config)
        XCTAssertEqual(res.primaryType, .color)
    }

    func testLaxModeExtractsNamedFromProse() {
        let typeDetector = ContentTypeDetector()
        var config = DetectorConfiguration.default
        var rule = config.rule(for: .color)
        rule.strictnessOverride = .lax
        config.setRule(rule, for: .color)

        let res = typeDetector.detect(in: "I love the color cornflowerblue.", configuration: config)
        // Should contain a colors entry in metadata even if primary type is prose/text.
        XCTAssertNotNil(res.metadataJSON)
        XCTAssertTrue(res.metadataJSON?.contains("cornflowerblue") ?? false)
    }
}
