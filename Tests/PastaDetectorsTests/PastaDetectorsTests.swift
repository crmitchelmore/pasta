import XCTest
@testable import PastaDetectors

final class PastaDetectorsTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(PastaDetectors.version, "0.1.0")
    }

    func testIPAddressDetector() {
        let detector = IPAddressDetector()
        let results = detector.detect(in: "Public 8.8.8.8 and private 10.0.0.1")
        XCTAssertEqual(results.map(\.address), ["8.8.8.8", "10.0.0.1"])
        XCTAssertTrue(results.contains(where: { $0.isPrivate }))
        XCTAssertTrue(results.contains(where: { $0.isLoopback == false }))
    }

    func testUUIDDetector() {
        let detector = UUIDDetector()
        let results = detector.detect(in: "uuid 550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(results.map(\.uuid), ["550e8400-e29b-41d4-a716-446655440000"])
        XCTAssertEqual(results.first?.variant, "rfc4122")
    }

    func testHashDetector() {
        let detector = HashDetector()
        let results = detector.detect(in: "hash 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        XCTAssertEqual(results.map(\.kind), ["sha256"])
        XCTAssertEqual(results.first?.bitLength, 256)
    }
}
