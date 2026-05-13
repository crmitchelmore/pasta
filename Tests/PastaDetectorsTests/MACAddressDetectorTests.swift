import XCTest
@testable import PastaDetectors

final class MACAddressDetectorTests: XCTestCase {
    func testDetectsColonForm() {
        let detector = MACAddressDetector()
        let detections = detector.detect(in: "iface 00:1A:2B:3C:4D:5E up", strictness: .strict)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.normalized, "00:1A:2B:3C:4D:5E")
        XCTAssertEqual(detections.first?.isMulticast, false)
        XCTAssertEqual(detections.first?.isLocallyAdministered, false)
    }

    func testStrictRejectsDashAndCisco() {
        let detector = MACAddressDetector()
        let text = "00-1A-2B-3C-4D-5E and 0011.2233.4455"
        XCTAssertEqual(detector.detect(in: text, strictness: .strict).count, 0)
    }

    func testMediumAcceptsDashRejectsCisco() {
        let detector = MACAddressDetector()
        let text = "00-1A-2B-3C-4D-5E and 0011.2233.4455"
        let detections = detector.detect(in: text, strictness: .medium)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.normalized, "00:1A:2B:3C:4D:5E")
    }

    func testLaxAcceptsCisco() {
        let detector = MACAddressDetector()
        let detections = detector.detect(in: "0011.2233.4455", strictness: .lax)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.normalized, "00:11:22:33:44:55")
    }

    func testMulticastAndLocallyAdministeredFlags() {
        let detector = MACAddressDetector()
        // 03 = 0000 0011 -> bit0 set (multicast), bit1 set (local)
        let detections = detector.detect(in: "03:00:00:00:00:01", strictness: .strict)
        XCTAssertEqual(detections.first?.isMulticast, true)
        XCTAssertEqual(detections.first?.isLocallyAdministered, true)

        let unicast = detector.detect(in: "00:11:22:33:44:55", strictness: .strict)
        XCTAssertEqual(unicast.first?.isMulticast, false)
        XCTAssertEqual(unicast.first?.isLocallyAdministered, false)
    }

    func testIgnoresShortAndJunk() {
        let detector = MACAddressDetector()
        XCTAssertTrue(detector.detect(in: "GG:HH:II:JJ:KK:LL", strictness: .lax).isEmpty)
        XCTAssertTrue(detector.detect(in: "00:1A:2B:3C:4D", strictness: .lax).isEmpty)
    }

    func testDeduplicatesAcrossFormats() {
        let detector = MACAddressDetector()
        let text = "00:11:22:33:44:55 / 00-11-22-33-44-55 / 0011.2233.4455"
        let detections = detector.detect(in: text, strictness: .lax)
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.normalized, "00:11:22:33:44:55")
    }
}
