import PastaCore
import XCTest
@testable import PastaDetectors

final class ContentTypeDetectorTests: XCTestCase {
    private typealias Support = DetectorTestSupport

    func testPrimaryClassificationAndMetadataTable() throws {
        let detector = ContentTypeDetector(jwtDetector: JWTDetector(now: { Date(timeIntervalSince1970: 2_000) }))
        let jwt = Support.makeJWT(header: #"{"alg":"HS256"}"#, payload: #"{"exp":2500}"#, signature: "sig")
        let cases: [(name: String, input: String, primary: ContentType, metadataKey: String?)] = [
            ("bearer jwt", "Bearer \(jwt)", .jwt, "jwt"),
            ("url in text", "See https://example.com", .url, nil),
            ("percent-encoded url is classified decoded", "https%3A%2F%2Fgithub.com%2Fgroue%2FGRDB.swift", .url, "encoding"),
            ("ip address", "ping 192.168.1.5", .ipAddress, "ipAddresses"),
            ("uuid", "id=550e8400-e29b-41d4-a716-446655440000", .uuid, "uuids"),
            ("hash", "sha256=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", .hash, "hashes"),
            ("bare email", "user@example.com", .email, nil),
            ("bare url", "https://example.com/docs", .url, nil),
            ("hex colour", "#ff8800", .color, "colors"),
            ("empty input", "   \n", .unknown, nil),
        ]
        for c in cases {
            let out = detector.detect(in: c.input)
            XCTAssertEqual(out.primaryType, c.primary, "case \(c.name)")
            if let key = c.metadataKey {
                XCTAssertNotNil(Support.parseJSON(out.metadataJSON)?[key], "case \(c.name): metadata \(key)")
            }
        }
        XCTAssertGreaterThanOrEqual(detector.detect(in: "Bearer \(jwt)").confidence, 0.9)

        let env = detector.detect(in: "export FOO=bar\nBAZ=qux")
        XCTAssertEqual(env.primaryType, .envVarBlock)
        XCTAssertEqual(env.splitEntries.map(\.content), ["export FOO=bar", "BAZ=qux"])
        XCTAssertTrue(env.splitEntries.allSatisfy { $0.contentType == .envVar })
        let envMeta = try XCTUnwrap(Support.parseJSON(env.metadataJSON)?["env"] as? [String: Any])
        XCTAssertEqual(envMeta["isBlock"] as? Bool, true)
    }

    func testAPIKeyDetectionRespectsTokenBoundaries() throws {
        let detector = ContentTypeDetector(jwtDetector: JWTDetector(now: { Date(timeIntervalSince1970: 2_000) }))
        // Long base64url JWT segments must not be reported as API keys.
        let token = Support.makeJWT(
            header: #"{"alg":"RS256","typ":"JWT","kid":"abc123"}"#,
            payload: #"{"sub":"user_2abc","iss":"https://clerk.example.com","iat":1500,"exp":2500,"azp":"app_2def","org_id":"org_2ghi","permissions":["read","write"]}"#,
            signature: String(repeating: "x", count: 64)
        )
        let out = detector.detect(in: token)
        XCTAssertEqual(out.primaryType, .jwt)
        XCTAssertNil(Support.parseJSON(out.metadataJSON)?["apiKeys"], "JWT should not produce false API key detections")

        let apiKeys = APIKeyDetector()
        let embedded = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzABCDEFGH"
        XCTAssertTrue(apiKeys.detect(in: embedded).filter { $0.provider.contains("AWS") }.isEmpty,
                      "40-char AWS secret pattern embedded in a longer run must not match")
        XCTAssertTrue(apiKeys.detect(in: "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij is live")
            .contains { $0.provider == "GitHub PAT" })
    }
}
