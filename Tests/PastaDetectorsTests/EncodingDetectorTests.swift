import XCTest
@testable import PastaDetectors

final class EncodingDetectorTests: XCTestCase {
    func testDetectsURLPercentEncoding() throws {
        let detector = EncodingDetector()
        let input = "hello%20world%21"
        let results = detector.detect(in: input)
        let detection = try XCTUnwrap(results.first)

        XCTAssertEqual(detection.original, input)
        XCTAssertEqual(detection.decoded, "hello world!")
        XCTAssertEqual(detection.steps.map(\.encoding.rawValue), ["url"])
        XCTAssertGreaterThanOrEqual(detection.confidence, 0.8)

        let metadata = try XCTUnwrap(detection.metadataJSON())
        XCTAssertTrue(metadata.contains("decodedPreview"))
        XCTAssertTrue(metadata.contains("hello world!"))
    }

    func testDetectsBase64() throws {
        let detector = EncodingDetector()
        let input = "SGVsbG8sIFBhc3RhIQ==" // "Hello, Pasta!"
        let results = detector.detect(in: input)
        let detection = try XCTUnwrap(results.first)

        XCTAssertEqual(detection.decoded, "Hello, Pasta!")
        XCTAssertEqual(detection.steps.map(\.encoding.rawValue), ["base64"])
    }

    func testHandlesNestedBase64ThenURLDecoding() throws {
        let detector = EncodingDetector()
        let input = "aGVsbG8lMjB3b3JsZCE=" // base64("hello%20world!")
        let results = detector.detect(in: input)
        let detection = try XCTUnwrap(results.first)

        XCTAssertEqual(detection.decoded, "hello world!")
        XCTAssertEqual(detection.steps.map(\.encoding.rawValue), ["base64", "url"])
        XCTAssertGreaterThanOrEqual(detection.confidence, 0.85)
    }

    func testRejectsNonEncodedPlainText() {
        let detector = EncodingDetector()
        XCTAssertTrue(detector.detect(in: "just some text").isEmpty)
    }
}
