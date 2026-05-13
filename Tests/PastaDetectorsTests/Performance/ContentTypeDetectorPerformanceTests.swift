import XCTest
@testable import PastaDetectors
import PastaCore

/// Performance benchmarks for the content-type detection pipeline.
///
/// These tests use XCTest's `measure { }` block. Run with:
///   swift test --filter ContentTypeDetectorPerformanceTests
///
/// Baseline numbers should be captured before any optimization pass and
/// re-measured afterwards to verify wins.
final class ContentTypeDetectorPerformanceTests: XCTestCase {
    private let detector = ContentTypeDetector()

    private static let shortURL = "Check out https://github.com/example/repo"
    // Build a JWT-shaped string at runtime from raw JSON. We avoid embedding
    // any literal base64-encoded JWT in source — even sample tokens get
    // flagged by GitHub's secret scanning, and we don't want benchmark inputs
    // to trip that machinery.
    private static let jwtToken: String = {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = b64url(#"{"sub":"benchmark","name":"perf","iat":1516239022}"#)
        let signature = String(repeating: "abcDEF123", count: 5)
        return [header, payload, signature].joined(separator: ".")
    }()

    // Build the env-var block at runtime to avoid embedding any token shape
    // (e.g. `sk_live_*`) that GitHub's secret scanner would flag, even when
    // the value is obviously a literal benchmark fixture.
    private static let envBlock: String = {
        let fakeKeyPrefix = ["sk", "test"].joined(separator: "_")
        let fakeKey = "\(fakeKeyPrefix)_" + String(repeating: "0", count: 32)
        return [
            "export DATABASE_URL=postgres://user:pass@localhost:5432/db",
            "export REDIS_URL=redis://localhost:6379",
            "export API_KEY=\(fakeKey)",
            "export NODE_ENV=production",
            "export PORT=8080",
            "export LOG_LEVEL=info"
        ].joined(separator: "\n")
    }()

    private static let codeSample = """
    func compute(_ items: [Int]) -> Int {
        var total = 0
        for item in items where item > 0 {
            total += item * 2
        }
        return total
    }

    let result = compute([1, 2, 3, 4, 5])
    print("result=\\(result)")
    """

    private static let longProse: String = {
        let para = """
        Lorem ipsum dolor sit amet, consectetur adipiscing elit. Reach out at \
        alice@example.com or visit https://example.com/docs for more info. The \
        ticket id is 550e8400-e29b-41d4-a716-446655440000 and the server runs at \
        10.0.0.42. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. \
        Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut \
        aliquip ex ea commodo consequat.
        """
        return Array(repeating: para, count: 6).joined(separator: "\n\n")
    }()

    func testDetectShortURL() {
        measure {
            for _ in 0..<200 {
                _ = detector.detect(in: Self.shortURL)
            }
        }
    }

    func testDetectLongProseWithEmbeddedItems() {
        measure {
            for _ in 0..<20 {
                _ = detector.detect(in: Self.longProse)
            }
        }
    }

    func testDetectJWT() {
        measure {
            for _ in 0..<200 {
                _ = detector.detect(in: Self.jwtToken)
            }
        }
    }

    func testDetectEnvVarBlock() {
        measure {
            for _ in 0..<200 {
                _ = detector.detect(in: Self.envBlock)
            }
        }
    }

    func testDetectCodeBlock() {
        measure {
            for _ in 0..<200 {
                _ = detector.detect(in: Self.codeSample)
            }
        }
    }
}
