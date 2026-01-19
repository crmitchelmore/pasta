import XCTest
@testable import PastaDetectors

final class JWTDetectorTests: XCTestCase {
    func testDetectValidJWTAndExtractClaims() throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000)
        let detector = JWTDetector(now: { fixedNow })

        let header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"
        let payload = "{\"sub\":\"123\",\"iss\":\"issuer\",\"iat\":1500,\"exp\":2500}"
        let token = makeJWT(headerJSON: header, payloadJSON: payload, signature: "sig")

        let results = detector.detect(in: "Bearer \(token)")
        XCTAssertEqual(results.count, 1)

        let detection = try XCTUnwrap(results.first)
        XCTAssertEqual(detection.token, token)
        XCTAssertGreaterThanOrEqual(detection.confidence, 0.9)
        XCTAssertEqual(detection.claims.sub, "123")
        XCTAssertEqual(detection.claims.iss, "issuer")
        XCTAssertEqual(detection.claims.iat, Date(timeIntervalSince1970: 1500))
        XCTAssertEqual(detection.claims.exp, Date(timeIntervalSince1970: 2500))
        XCTAssertEqual(detection.isExpired, false)
    }

    func testDetectExpiredJWT() {
        let fixedNow = Date(timeIntervalSince1970: 2_000)
        let detector = JWTDetector(now: { fixedNow })

        let header = "{\"alg\":\"HS256\"}"
        let payload = "{\"exp\":1999}"
        let token = makeJWT(headerJSON: header, payloadJSON: payload, signature: "sig")

        let results = detector.detect(in: token)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.isExpired, true)
    }

    func testRejectMalformedJWT() {
        let detector = JWTDetector(now: { Date(timeIntervalSince1970: 0) })
        XCTAssertTrue(detector.detect(in: "not.a.jwt").isEmpty)
        XCTAssertTrue(detector.detect(in: "a.b").isEmpty)
        XCTAssertTrue(detector.detect(in: "a.b.c.d").isEmpty)
    }

    private func makeJWT(headerJSON: String, payloadJSON: String, signature: String) -> String {
        "\(base64url(headerJSON)).\(base64url(payloadJSON)).\(base64url(signature))"
    }

    private func base64url(_ s: String) -> String {
        let data = Data(s.utf8)
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
