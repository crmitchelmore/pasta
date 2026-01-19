import XCTest
@testable import PastaDetectors

final class ProseDetectorTests: XCTestCase {
    func testDetectsProseParagraph() {
        let detector = ProseDetector()
        let text = "SwiftUI makes building macOS apps delightful. This clipboard history app stores your snippets and helps you find them quickly."
        let detection = detector.detect(in: text)
        XCTAssertNotNil(detection)
        XCTAssertGreaterThanOrEqual(detection?.wordCount ?? 0, 12)
        XCTAssertGreaterThanOrEqual(detection?.confidence ?? 0, 0.6)
    }

    func testRejectsCode() {
        let detector = ProseDetector()
        let code = """
        import Foundation
        struct A { let x: Int }
        """
        XCTAssertNil(detector.detect(in: code))
    }

    func testRejectsStructuredEnvBlock() {
        let detector = ProseDetector()
        let env = """
        FOO=bar
        BAZ=qux
        """
        XCTAssertNil(detector.detect(in: env))
    }

    func testEstimatesReadingTime() {
        let detector = ProseDetector()
        let text = Array(repeating: "word", count: 200).joined(separator: " ") + "."
        let detection = detector.detect(in: text)
        XCTAssertEqual(detection?.wordCount, 200)
        XCTAssertEqual(detection?.estimatedReadingTimeSeconds, 60)
    }
}
