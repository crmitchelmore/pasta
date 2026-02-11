import XCTest
@testable import PastaDetectors

final class ContentTypeDetectorTests: XCTestCase {
    func testDetectsJWTAsPrimary() throws {
        let detector = ContentTypeDetector(jwtDetector: JWTDetector(now: { Date(timeIntervalSince1970: 2_000) }))

        let header = "{\"alg\":\"HS256\"}"
        let payload = "{\"exp\":2500}"
        let token = makeJWT(headerJSON: header, payloadJSON: payload, signature: "sig")

        let out = detector.detect(in: "Bearer \(token)")
        XCTAssertEqual(out.primaryType, .jwt)
        XCTAssertGreaterThanOrEqual(out.confidence, 0.9)

        let meta = try XCTUnwrap(parseJSON(out.metadataJSON))
        XCTAssertNotNil(meta["jwt"])
    }

    func testDetectsEnvVarBlockAndSplits() throws {
        let detector = ContentTypeDetector()
        let text = """
        export FOO=bar
        BAZ=qux
        """

        let out = detector.detect(in: text)
        XCTAssertEqual(out.primaryType, .envVarBlock)
        XCTAssertEqual(out.splitEntries.count, 2)
        XCTAssertTrue(out.splitEntries.allSatisfy { $0.contentType == .envVar })

        let meta = try XCTUnwrap(parseJSON(out.metadataJSON))
        let env = try XCTUnwrap(meta["env"] as? [String: Any])
        XCTAssertEqual(env["isBlock"] as? Bool, true)
    }

    func testPrefersURLWhenOnlyURLPresent() {
        let detector = ContentTypeDetector()
        let out = detector.detect(in: "See https://example.com")
        XCTAssertEqual(out.primaryType, .url)
    }

    func testUsesDecodedContentForClassification() {
        let detector = ContentTypeDetector()
        let encoded = "https%3A%2F%2Fgithub.com%2Fgroue%2FGRDB.swift"
        let out = detector.detect(in: encoded)
        XCTAssertEqual(out.primaryType, .url)
    }

    func testDetectsIPAddressAsPrimary() throws {
        let detector = ContentTypeDetector()
        let out = detector.detect(in: "ping 192.168.1.5")
        XCTAssertEqual(out.primaryType, .ipAddress)

        let meta = try XCTUnwrap(parseJSON(out.metadataJSON))
        XCTAssertNotNil(meta["ipAddresses"])
    }

    func testDetectsUUIDAsPrimary() throws {
        let detector = ContentTypeDetector()
        let out = detector.detect(in: "id=550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(out.primaryType, .uuid)

        let meta = try XCTUnwrap(parseJSON(out.metadataJSON))
        XCTAssertNotNil(meta["uuids"])
    }

    func testDetectsHashAsPrimary() throws {
        let detector = ContentTypeDetector()
        let out = detector.detect(in: "sha256=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        XCTAssertEqual(out.primaryType, .hash)

        let meta = try XCTUnwrap(parseJSON(out.metadataJSON))
        XCTAssertNotNil(meta["hashes"])
    }

    func testJWTDoesNotProduceFalseAPIKeyDetections() throws {
        let detector = ContentTypeDetector(jwtDetector: JWTDetector(now: { Date(timeIntervalSince1970: 2_000) }))

        // A realistic JWT with long base64url segments that could match broad API key patterns
        let header = "{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"abc123\"}"
        let payload = "{\"sub\":\"user_2abc\",\"iss\":\"https://clerk.example.com\",\"iat\":1500,\"exp\":2500,\"azp\":\"app_2def\",\"org_id\":\"org_2ghi\",\"permissions\":[\"read\",\"write\"]}"
        let token = makeJWT(headerJSON: header, payloadJSON: payload, signature: String(repeating: "x", count: 64))

        let out = detector.detect(in: token)
        XCTAssertEqual(out.primaryType, .jwt)

        let meta = try XCTUnwrap(parseJSON(out.metadataJSON))
        // Must not contain false positive API keys from JWT segments
        let apiKeys = meta["apiKeys"] as? [[String: Any]]
        XCTAssertNil(apiKeys, "JWT should not produce false API key detections")
    }

    func testAPIKeyBoundaryEnforcementPreventsEmbeddedMatches() {
        let detector = APIKeyDetector()

        // An AWS secret key pattern embedded in a longer string (no whitespace boundary)
        let embedded = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzABCDEFGH"
        let detections = detector.detect(in: embedded)
        // Should not match because the 40-char AWS pattern is embedded in a longer run
        let awsKeys = detections.filter { $0.provider.contains("AWS") }
        XCTAssertTrue(awsKeys.isEmpty, "Should not detect embedded AWS key without boundary")
    }

    func testAPIKeyWithWhitespaceBoundaryIsDetected() {
        let detector = APIKeyDetector()

        let key = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let detections = detector.detect(in: "token: \(key) is live")
        XCTAssertTrue(detections.contains(where: { $0.provider == "GitHub PAT" }))
    }

    private func parseJSON(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
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
