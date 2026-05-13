import XCTest
@testable import PastaDetectors

final class ColorDetectorTests: XCTestCase {
    private let detector = ColorDetector()

    // MARK: - Hex

    func testDetectHex6() {
        let r = detector.detect(in: "#FF8800").first
        XCTAssertEqual(r?.format, .hex)
        XCTAssertEqual(r?.red, 0xFF)
        XCTAssertEqual(r?.green, 0x88)
        XCTAssertEqual(r?.blue, 0x00)
        XCTAssertEqual(r?.alpha, 1.0)
    }

    func testDetectHex3Expansion() {
        let r = detector.detect(in: "#f80").first
        XCTAssertEqual(r?.red, 0xFF)
        XCTAssertEqual(r?.green, 0x88)
        XCTAssertEqual(r?.blue, 0x00)
    }

    func testDetectHex8WithAlpha() {
        let r = detector.detect(in: "#11223380").first
        XCTAssertEqual(r?.red, 0x11)
        XCTAssertEqual(r?.green, 0x22)
        XCTAssertEqual(r?.blue, 0x33)
        XCTAssertEqual(r?.alpha ?? 0, 0x80 / 255.0, accuracy: 0.001)
    }

    func testDetectHex4WithAlpha() {
        let r = detector.detect(in: "#1238").first
        XCTAssertEqual(r?.red, 0x11)
        XCTAssertEqual(r?.green, 0x22)
        XCTAssertEqual(r?.blue, 0x33)
        XCTAssertEqual(r?.alpha ?? 0, 0x88 / 255.0, accuracy: 0.001)
    }

    // MARK: - rgb / rgba

    func testDetectRGBLegacy() {
        let r = detector.detect(in: "rgb(255, 128, 0)").first
        XCTAssertEqual(r?.format, .rgb)
        XCTAssertEqual(r?.red, 255)
        XCTAssertEqual(r?.green, 128)
        XCTAssertEqual(r?.blue, 0)
    }

    func testDetectRGBModernSpace() {
        let r = detector.detect(in: "rgb(255 128 0)").first
        XCTAssertEqual(r?.format, .rgb)
        XCTAssertEqual(r?.red, 255)
        XCTAssertEqual(r?.green, 128)
        XCTAssertEqual(r?.blue, 0)
    }

    func testDetectRGBPercent() {
        let r = detector.detect(in: "rgb(100%, 50%, 0%)").first
        XCTAssertEqual(r?.red, 255)
        XCTAssertEqual(r?.green, 128)
        XCTAssertEqual(r?.blue, 0)
    }

    func testDetectRGBAComma() {
        let r = detector.detect(in: "rgba(10, 20, 30, 0.5)").first
        XCTAssertEqual(r?.format, .rgba)
        XCTAssertEqual(r?.red, 10)
        XCTAssertEqual(r?.green, 20)
        XCTAssertEqual(r?.blue, 30)
        XCTAssertEqual(r?.alpha ?? 0, 0.5, accuracy: 0.001)
    }

    func testDetectRGBSlashAlpha() {
        let r = detector.detect(in: "rgb(255 0 0 / 0.25)").first
        XCTAssertEqual(r?.format, .rgba)
        XCTAssertEqual(r?.alpha ?? 0, 0.25, accuracy: 0.001)
    }

    func testRejectRGBOutOfRange() {
        let r = detector.detect(in: "rgb(300, 0, 0)")
        XCTAssertTrue(r.isEmpty, "Out-of-range channel should not match")
    }

    // MARK: - hsl / hsla

    func testDetectHSLPureRed() {
        let r = detector.detect(in: "hsl(0, 100%, 50%)").first
        XCTAssertEqual(r?.format, .hsl)
        XCTAssertEqual(r?.red, 255)
        XCTAssertEqual(r?.green, 0)
        XCTAssertEqual(r?.blue, 0)
    }

    func testDetectHSLBlue() {
        let r = detector.detect(in: "hsl(240, 100%, 50%)").first
        XCTAssertEqual(r?.red, 0)
        XCTAssertEqual(r?.green, 0)
        XCTAssertEqual(r?.blue, 255)
    }

    func testDetectHSLAModern() {
        let r = detector.detect(in: "hsl(120 100% 25% / 0.5)").first
        XCTAssertEqual(r?.format, .hsla)
        XCTAssertEqual(r?.red, 0)
        XCTAssertEqual(r?.green, 128)
        XCTAssertEqual(r?.blue, 0)
        XCTAssertEqual(r?.alpha ?? 0, 0.5, accuracy: 0.001)
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
