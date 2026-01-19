import XCTest
@testable import PastaDetectors

final class EnvVarDetectorTests: XCTestCase {
    func testDetectSingleEnvVar() throws {
        let detector = EnvVarDetector()
        let output = try XCTUnwrap(detector.detect(in: "API_KEY=abc123"))
        XCTAssertEqual(output.isBlock, false)
        XCTAssertEqual(output.detections.map(\.key), ["API_KEY"])
        XCTAssertEqual(output.detections.map(\.value), ["abc123"])
        XCTAssertEqual(output.detections.first?.isExported, false)
        XCTAssertGreaterThanOrEqual(output.detections.first?.confidence ?? 0, 0.7)
    }

    func testDetectExportAndQuotedValue() throws {
        let detector = EnvVarDetector()
        let output = try XCTUnwrap(detector.detect(in: "export NAME=\"hello world\""))
        XCTAssertEqual(output.isBlock, false)
        XCTAssertEqual(output.detections.first?.key, "NAME")
        XCTAssertEqual(output.detections.first?.value, "hello world")
        XCTAssertEqual(output.detections.first?.isExported, true)
    }

    func testDetectEnvVarBlockSkipsCommentsAndBlanks() throws {
        let detector = EnvVarDetector()
        let text = """
        # comment
        FOO=bar

        BAZ='qux'
        """

        let output = try XCTUnwrap(detector.detect(in: text))
        XCTAssertEqual(output.isBlock, true)
        XCTAssertEqual(output.detections.map(\.key), ["FOO", "BAZ"])
        XCTAssertEqual(output.detections.map(\.value), ["bar", "qux"])
    }

    func testRejectWhenNoAssignments() {
        let detector = EnvVarDetector()
        XCTAssertNil(detector.detect(in: "not an env var"))
    }
}
