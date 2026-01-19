import XCTest
@testable import PastaDetectors

final class URLDetectorTests: XCTestCase {
    func testDetectsHTTPAndHTTPSAndFTP() {
        let detector = URLDetector()
        let text = "See https://github.com/groue/GRDB.swift and http://example.com and ftp://example.com/file"
        let detections = detector.detect(in: text)

        XCTAssertEqual(detections.count, 3)
        XCTAssertTrue(detections.contains(where: { $0.domain == "github.com" && $0.category == "github" }))
        XCTAssertTrue(detections.contains(where: { $0.domain == "example.com" }))
    }

    func testIgnoresNonSupportedSchemes() {
        let detector = URLDetector()
        let text = "mailto:test@example.com file:///Users/me/test.txt"
        let detections = detector.detect(in: text)
        XCTAssertTrue(detections.isEmpty)
    }

    func testDedupesDuplicateURLs() {
        let detector = URLDetector()
        let text = "https://example.com https://example.com"
        let detections = detector.detect(in: text)
        XCTAssertEqual(detections.map(\.url), ["https://example.com"]) // preserve first occurrence
    }

    func testCategorizesKnownDomains() {
        let detector = URLDetector()
        let detections = detector.detect(in: "https://stackoverflow.com/questions/123")
        XCTAssertEqual(detections.first?.category, "stackoverflow")
    }

    func testHandlesURLPercentEncodedText() {
        let detector = URLDetector()
        let text = "https%3A%2F%2Fgithub.com%2Fgroue%2FGRDB.swift"
        let detections = detector.detect(in: text)
        XCTAssertEqual(detections.first?.domain, "github.com")
        XCTAssertEqual(detections.first?.category, "github")
    }
}
