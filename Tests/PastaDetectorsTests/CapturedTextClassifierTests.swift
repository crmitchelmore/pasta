import PastaCore
import XCTest
@testable import PastaDetectors

final class CapturedTextClassifierTests: XCTestCase {
    func testCapturedTextKeepsDetectedTypeAndMetadata() {
        let jwt = DetectorTestSupport.makeJWT(header: #"{"alg":"HS256"}"#, payload: #"{"sub":"1"}"#, signature: "sig")
        let cases: [(name: String, input: String, type: ContentType, mask: ContentTypeMask)] = [
            ("url", "https://example.com/docs", .url, .url),
            ("email", "user@example.com", .email, .email),
            ("env var", "API_KEY=example-value", .envVar, .envVar),
            ("jwt", jwt, .jwt, .jwt),
            ("uuid", "550e8400-e29b-41d4-a716-446655440000", .uuid, .uuid),
            ("single character falls back to text", "x", .text, []),
        ]
        for c in cases {
            let entry = CapturedTextClassifier.entry(content: c.input, sourceApp: "iOS Pasteboard")
            XCTAssertEqual(entry.contentType, c.type, "case \(c.name)")
            XCTAssertTrue(entry.contentTypeMask.isSuperset(of: c.mask), "case \(c.name): mask \(entry.contentTypeMask)")
            XCTAssertEqual(entry.content, c.input, "case \(c.name)")
            XCTAssertNil(entry.parentEntryId)
        }

        let mixed = CapturedTextClassifier.entry(
            content: "Call me on 020 7946 0958 or email user@example.com about https://example.com/a",
            sourceApp: nil
        )
        XCTAssertTrue(mixed.contentTypeMask.contains(.email))
        XCTAssertTrue(mixed.contentTypeMask.contains(.url))
        XCTAssertFalse(MetadataParser.extractAllValues(from: mixed.metadata, limit: 10, content: mixed.content).isEmpty)
    }
}
