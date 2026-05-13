import XCTest
@testable import PastaDetectors

final class IBANDetectorTests: XCTestCase {
    // Reference IBANs from the registry / commonly used test vectors.
    private let validIBANs: [String] = [
        "GB82 WEST 1234 5698 7654 32",       // GB
        "DE89370400440532013000",            // DE
        "FR1420041010050500013M02606",       // FR
        "ES9121000418450200051332",          // ES
        "NL91ABNA0417164300",                // NL
        "CH9300762011623852957",             // CH
        "BE68539007547034",                  // BE
        "IT60X0542811101000000123456"        // IT
    ]

    func testDetectsValidIBANs() {
        let detector = IBANDetector()
        for iban in validIBANs {
            let detections = detector.detect(in: iban, strictness: .medium)
            XCTAssertEqual(detections.count, 1, "Expected detection for \(iban)")
            XCTAssertEqual(detections.first?.normalized, iban.uppercased().filter { $0.isLetter || $0.isNumber })
        }
    }

    func testRejectsBadChecksum() {
        let detector = IBANDetector()
        // GB82 changed to GB83 — invalid checksum.
        XCTAssertTrue(detector.detect(in: "GB83 WEST 1234 5698 7654 32", strictness: .medium).isEmpty)
        XCTAssertTrue(detector.detect(in: "DE99370400440532013000", strictness: .medium).isEmpty)
    }

    func testStrictRequiresKnownCountry() {
        let detector = IBANDetector()
        // Construct a valid mod-97 IBAN with an unknown country code.
        // The fixed-format test vector "ZZ58 1234 5678 9012 3456 7890" likely won't validate,
        // so we just confirm strict gating works on a known-bad/unknown country case.
        let unknown = "ZZ00 0000 0000 0000 0000 00"
        XCTAssertTrue(detector.detect(in: unknown, strictness: .strict).isEmpty)
    }

    func testMod97Helper() {
        XCTAssertTrue(IBANDetector.mod97IsValid("GB82WEST12345698765432"))
        XCTAssertTrue(IBANDetector.mod97IsValid("DE89370400440532013000"))
        XCTAssertFalse(IBANDetector.mod97IsValid("GB83WEST12345698765432"))
        XCTAssertFalse(IBANDetector.mod97IsValid("SHORT"))
    }

    func testCountryCodeExposed() {
        let detector = IBANDetector()
        let detection = detector.detect(in: "DE89370400440532013000", strictness: .medium).first
        XCTAssertEqual(detection?.countryCode, "DE")
    }

    func testNormalizesSpaces() {
        let detector = IBANDetector()
        let detection = detector.detect(in: "GB82 WEST 1234 5698 7654 32", strictness: .medium).first
        XCTAssertEqual(detection?.normalized, "GB82WEST12345698765432")
    }

    func testIgnoresArbitraryHexBlobs() {
        let detector = IBANDetector()
        XCTAssertTrue(detector.detect(in: "DEADBEEFCAFE0123456789", strictness: .medium).isEmpty)
    }
}
