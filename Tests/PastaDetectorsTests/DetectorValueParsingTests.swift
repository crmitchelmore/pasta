import PastaCore
import XCTest
@testable import PastaDetectors

/// Per-family field parsing that the classification tables cannot observe:
/// normalisation, checksums, flags, decoded values and language detection.
final class DetectorValueParsingTests: XCTestCase {
    func testNetworkAndIdentifierDetectors() {
        let ips = IPAddressDetector().detect(in: "Public 8.8.8.8 and private 10.0.0.1")
        XCTAssertEqual(ips.map(\.address), ["8.8.8.8", "10.0.0.1"])
        XCTAssertEqual(ips.map(\.isPrivate), [false, true])
        XCTAssertFalse(ips.contains { $0.isLoopback })

        let uuids = UUIDDetector().detect(in: "uuid 550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(uuids.map(\.uuid), ["550e8400-e29b-41d4-a716-446655440000"])
        XCTAssertEqual(uuids.first?.variant, "rfc4122")

        let hashes = HashDetector().detect(in: "hash 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        XCTAssertEqual(hashes.map(\.kind), ["sha256"])
        XCTAssertEqual(hashes.first?.bitLength, 256)

        let mac = MACAddressDetector()
        let flagCases: [(input: String, multicast: Bool, local: Bool)] = [
            ("00:1A:2B:3C:4D:5E", false, false),
            // 03 = 0000 0011 -> bit0 multicast, bit1 locally administered
            ("03:00:00:00:00:01", true, true),
        ]
        for c in flagCases {
            let d = mac.detect(in: c.input, strictness: .strict).first
            XCTAssertEqual(d?.isMulticast, c.multicast, "case \(c.input)")
            XCTAssertEqual(d?.isLocallyAdministered, c.local, "case \(c.input)")
        }
    }

    func testFinancialDetectorsValidateChecksumsAndBrands() {
        let ibanDetector = IBANDetector()
        let validIBANs = [
            "GB82 WEST 1234 5698 7654 32", "DE89370400440532013000", "FR1420041010050500013M02606",
            "ES9121000418450200051332", "NL91ABNA0417164300", "CH9300762011623852957",
            "BE68539007547034", "IT60X0542811101000000123456",
        ]
        for iban in validIBANs {
            let detections = ibanDetector.detect(in: iban, strictness: .medium)
            XCTAssertEqual(detections.map(\.normalized), [iban.filter { $0.isLetter || $0.isNumber }], "case \(iban)")
            XCTAssertEqual(detections.first?.countryCode, String(iban.prefix(2)), "case \(iban)")
        }
        for invalid in ["GB83 WEST 1234 5698 7654 32", "DE99370400440532013000", "DEADBEEFCAFE0123456789"] {
            XCTAssertTrue(ibanDetector.detect(in: invalid, strictness: .medium).isEmpty, "case \(invalid)")
        }
        XCTAssertFalse(IBANDetector.mod97IsValid("SHORT"))

        let cardDetector = CreditCardDetector()
        let brands: [(pan: String, brand: String)] = [
            ("4111111111111111", "Visa"), ("5555555555554444", "Mastercard"), ("378282246310005", "Amex"),
            ("6011111111111117", "Discover"), ("2223000048400011", "Mastercard"),
        ]
        for c in brands {
            XCTAssertEqual(cardDetector.detect(in: c.pan, strictness: .medium).first?.brand, c.brand, "case \(c.pan)")
        }
        for invalid in ["4111 1111 1111 1112", "1234567"] {
            XCTAssertTrue(cardDetector.detect(in: invalid, strictness: .medium).isEmpty, "case \(invalid)")
        }
        let separated = cardDetector.detect(in: "card: 4111-1111-1111-1111 ok", strictness: .medium)
        XCTAssertEqual(separated.map(\.normalized), ["4111111111111111"])
        XCTAssertEqual(separated.first?.last4, "1111")
        XCTAssertEqual(separated.first?.maskedDisplay, "**** **** **** 1111")
    }

    func testColorParsingTable() {
        let detector = ColorDetector()
        let cases: [(input: String, format: ColorDetector.Format?, rgb: [UInt8], alpha: Double?)] = [
            ("#FF8800", .hex, [0xFF, 0x88, 0x00], 1.0),
            ("#f80", nil, [0xFF, 0x88, 0x00], nil),
            ("#11223380", nil, [0x11, 0x22, 0x33], 0x80 / 255.0),
            ("#1238", nil, [0x11, 0x22, 0x33], 0x88 / 255.0),
            ("rgb(255, 128, 0)", .rgb, [255, 128, 0], nil),
            ("rgb(255 128 0)", .rgb, [255, 128, 0], nil),
            ("rgb(100%, 50%, 0%)", nil, [255, 128, 0], nil),
            ("rgba(10, 20, 30, 0.5)", .rgba, [10, 20, 30], 0.5),
            ("rgb(255 0 0 / 0.25)", .rgba, [255, 0, 0], 0.25),
            ("hsl(0, 100%, 50%)", .hsl, [255, 0, 0], nil),
            ("hsl(240, 100%, 50%)", nil, [0, 0, 255], nil),
            ("hsl(120 100% 25% / 0.5)", .hsla, [0, 128, 0], 0.5),
            ("cornflowerblue", .named, [100, 149, 237], nil),
        ]
        for c in cases {
            let r = detector.detect(in: c.input).first
            if let format = c.format { XCTAssertEqual(r?.format, format, "case \(c.input)") }
            XCTAssertEqual(r.map { [$0.red, $0.green, $0.blue] }, c.rgb, "case \(c.input)")
            if let alpha = c.alpha { XCTAssertEqual(r?.alpha ?? -1, alpha, accuracy: 0.001, "case \(c.input)") }
        }
        // Out-of-range channels, bad hex lengths, hex glued to identifiers and named colours in prose.
        for rejected in ["rgb(300, 0, 0)", "#ZZ", "#12345", "abc#FF0000", "the sky is blue today"] {
            XCTAssertTrue(detector.detect(in: rejected).isEmpty, "case \(rejected)")
        }
        let extracted = detector.detect(in: "the red car", namedColorPolicy: .extract)
        XCTAssertEqual(extracted.first?.format, .named)
        XCTAssertEqual(extracted.first?.red, 255)
    }

    func testEmailURLAndEnvVarDetectors() throws {
        let email = EmailDetector()
        XCTAssertEqual(email.detect(in: "Contact me at test@example.com.").map(\.email), ["test@example.com"])
        XCTAssertGreaterThanOrEqual(email.detect(in: "test@example.com").first?.confidence ?? 0, 0.9)
        XCTAssertEqual(email.detect(in: "A a@example.com B A@EXAMPLE.COM C b@example.co.uk").map(\.email),
                       ["a@example.com", "b@example.co.uk"])
        XCTAssertTrue(email.detect(in: "bad@ example.com also bad@@example.com and @example.com and a@b").isEmpty)
        XCTAssertEqual(email.detect(in: "xxa@example.comyy").map(\.email), ["xxa@example.comyy"])

        let url = URLDetector()
        let urls = url.detect(in: "See https://github.com/groue/GRDB.swift and http://example.com and ftp://example.com/file https://example.com/x https://example.com/x")
        XCTAssertEqual(urls.count, 4, "duplicates collapse to the first occurrence")
        XCTAssertTrue(urls.contains { $0.domain == "github.com" && $0.category == "github" })
        XCTAssertTrue(url.detect(in: "mailto:test@example.com file:///Users/me/test.txt").isEmpty)
        XCTAssertEqual(url.detect(in: "https://stackoverflow.com/questions/123").first?.category, "stackoverflow")
        let decoded = url.detect(in: "https%3A%2F%2Fgithub.com%2Fgroue%2FGRDB.swift").first
        XCTAssertEqual(decoded?.domain, "github.com")
        XCTAssertEqual(decoded?.category, "github")
        for text in ["See https://github.com/a and http://Example.com/a and ftp://example.com/file",
                     "https%3A%2F%2Fdocs.google.com%2Fdocument%2Fd%2F1", "mailto:test@example.com", ""] {
            let expected = Set(url.detect(in: text).map(\.domain))
            XCTAssertEqual(URLDetector.domains(in: text), expected, text)
            XCTAssertEqual(URLDetector.domains(in: text), expected, "cached: \(text)")
        }

        let env = EnvVarDetector()
        let cases: [(input: String, isBlock: Bool, keys: [String], values: [String], exported: [Bool])] = [
            ("API_KEY=abc123", false, ["API_KEY"], ["abc123"], [false]),
            (#"export NAME="hello world""#, false, ["NAME"], ["hello world"], [true]),
            ("# comment\nFOO=bar\n\nBAZ='qux'", true, ["FOO", "BAZ"], ["bar", "qux"], [false, false]),
        ]
        for c in cases {
            let out = try XCTUnwrap(env.detect(in: c.input), "case \(c.input)")
            XCTAssertEqual(out.isBlock, c.isBlock, "case \(c.input)")
            XCTAssertEqual(out.detections.map(\.key), c.keys, "case \(c.input)")
            XCTAssertEqual(out.detections.map(\.value), c.values, "case \(c.input)")
            XCTAssertEqual(out.detections.map(\.isExported), c.exported, "case \(c.input)")
        }
        XCTAssertGreaterThanOrEqual(env.detect(in: "API_KEY=abc123")?.detections.first?.confidence ?? 0, 0.7)
        XCTAssertNil(env.detect(in: "not an env var"))
    }

    func testJWTAndEncodingDetectors() throws {
        let jwt = JWTDetector(now: { Date(timeIntervalSince1970: 2_000) })
        let token = DetectorTestSupport.makeJWT(
            header: #"{"alg":"HS256","typ":"JWT"}"#,
            payload: #"{"sub":"123","iss":"issuer","iat":1500,"exp":2500}"#, signature: "sig")
        let detection = try XCTUnwrap(jwt.detect(in: "Bearer \(token)").first)
        XCTAssertEqual(detection.token, token)
        XCTAssertGreaterThanOrEqual(detection.confidence, 0.9)
        XCTAssertEqual(detection.claims.sub, "123")
        XCTAssertEqual(detection.claims.iss, "issuer")
        XCTAssertEqual(detection.claims.iat, Date(timeIntervalSince1970: 1500))
        XCTAssertEqual(detection.claims.exp, Date(timeIntervalSince1970: 2500))
        XCTAssertEqual(detection.isExpired, false)
        let expired = DetectorTestSupport.makeJWT(header: #"{"alg":"HS256"}"#, payload: #"{"exp":1999}"#, signature: "sig")
        XCTAssertEqual(jwt.detect(in: expired).first?.isExpired, true)
        for malformed in ["not.a.jwt", "a.b", "a.b.c.d"] {
            XCTAssertTrue(jwt.detect(in: malformed).isEmpty, "case \(malformed)")
        }

        let encoding = EncodingDetector()
        let cases: [(input: String, decoded: String, steps: [String], minConfidence: Double)] = [
            ("hello%20world%21", "hello world!", ["url"], 0.8),
            ("SGVsbG8sIFBhc3RhIQ==", "Hello, Pasta!", ["base64"], 0),
            ("aGVsbG8lMjB3b3JsZCE=", "hello world!", ["base64", "url"], 0.85),
        ]
        for c in cases {
            let d = try XCTUnwrap(encoding.detect(in: c.input).first, "case \(c.input)")
            XCTAssertEqual(d.original, c.input)
            XCTAssertEqual(d.decoded, c.decoded, "case \(c.input)")
            XCTAssertEqual(d.steps.map(\.encoding.rawValue), c.steps, "case \(c.input)")
            XCTAssertGreaterThanOrEqual(d.confidence, c.minConfidence, "case \(c.input)")
        }
        let metadata = try XCTUnwrap(encoding.detect(in: "hello%20world%21").first?.metadataJSON())
        XCTAssertTrue(metadata.contains("decodedPreview") && metadata.contains("hello world!"))
        XCTAssertTrue(encoding.detect(in: "just some text").isEmpty)
    }

    func testCodeLanguageAndProseDetectors() {
        let code = CodeDetector()
        let cases: [(snippet: String, language: CodeLanguage)] = [
            ("import SwiftUI\nstruct ContentView: View {\n    var body: some View { Text(\"Hi\") }\n}", .swift),
            ("def hello():\n    print('hi')", .python),
            ("const fn = () => console.log('hi');\nexport function hello() { return 1; }", .javaScript),
            ("interface User { id: number }\nconst u: User = { id: 1 }", .typeScript),
            ("package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"hi\") }", .go),
            ("fn main() {\n    println!(\"hi\");\n}", .rust),
            ("public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"hi\");\n    }\n}", .java),
            ("#include <stdio.h>\nint main() { return 0; }", .cCpp),
            ("def hello\n  puts 'hi'\nend", .ruby),
            ("SELECT * FROM users WHERE id = 1;", .sql),
            (#"{"a":1,"b":[true,false]}"#, .json),
            ("name: Pasta\nversion: 1\nitems:\n  - a", .yaml),
            ("<html><body>Hello</body></html>", .html),
            ("body { color: red; }", .css),
            ("export FOO=bar\ncd /tmp\necho hi", .shell),
        ]
        for c in cases {
            XCTAssertEqual(code.detect(in: c.snippet).first?.language, c.language, "case \(c.language):\n\(c.snippet)")
        }
        XCTAssertGreaterThanOrEqual(code.detect(in: cases[0].snippet).first?.confidence ?? 0, 0.8)
        XCTAssertGreaterThanOrEqual(code.detect(in: cases[10].snippet).first?.confidence ?? 0, 0.9)

        let prose = ProseDetector()
        let paragraph = prose.detect(in: "SwiftUI makes building macOS apps delightful. This clipboard history app stores your snippets and helps you find them quickly.")
        XCTAssertGreaterThanOrEqual(paragraph?.wordCount ?? 0, 12)
        XCTAssertGreaterThanOrEqual(paragraph?.confidence ?? 0, 0.6)
        XCTAssertNil(prose.detect(in: "import Foundation\nstruct A { let x: Int }"))
        XCTAssertNil(prose.detect(in: "FOO=bar\nBAZ=qux"))
        let long = prose.detect(in: Array(repeating: "word", count: 200).joined(separator: " ") + ".")
        XCTAssertEqual(long?.wordCount, 200)
        XCTAssertEqual(long?.estimatedReadingTimeSeconds, 60)
    }

    func testFilePathDetectionAndExistenceChecks() throws {
        let detector = FilePathDetector()
        let unix = detector.detect(in: "Open ~/Library/Preferences/com.apple.Finder.plist and /tmp/test.txt")
        XCTAssertEqual(unix.count, 2)
        XCTAssertTrue(unix[0].path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path), "tilde expands")
        XCTAssertEqual(unix.map(\.filename), ["com.apple.Finder.plist", "test.txt"])
        XCTAssertEqual(unix.map(\.fileExtension), ["plist", "txt"])
        let windows = detector.detect(in: "See C:\\Users\\me\\file.txt and also C:/Windows/System32/drivers/etc/hosts")
        XCTAssertEqual(windows.map(\.filename), ["file.txt", "hosts"])
        XCTAssertEqual(windows.map(\.fileExtension), ["txt", nil])
        XCTAssertEqual(detector.detect(in: "/tmp/a /tmp/a").map(\.path), ["/tmp/a"])

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let realFile = temp.appendingPathComponent("real.txt")
        try Data("hi".utf8).write(to: realFile)

        let single = detector.detect(in: "Path: \(realFile.path)")
        XCTAssertEqual(single.map(\.path), [realFile.path])
        XCTAssertEqual(single.first?.exists, true)
        XCTAssertGreaterThanOrEqual(single.first?.confidence ?? 0, 0.85)

        // Build-log pastes: the stat budget is capped, and paths past it are "not checked", never "missing".
        let limit = FilePathDetector.defaultExistenceCheckLimit
        let capped = detector.detect(in: ((0..<limit).map { "/nonexistent/pasta-cap/file-\($0).log" } + [realFile.path]).joined(separator: "\n"))
        XCTAssertEqual(capped.count, limit + 1)
        XCTAssertNil(capped[limit].exists)
        XCTAssertEqual(capped[limit].confidence, 0.7, accuracy: 0.001)

        // Duplicates collapse before spending budget.
        let dupes = detector.detect(in: (Array(repeating: "/nonexistent/pasta-dup/same.log", count: 50) + [realFile.path]).joined(separator: "\n"))
        XCTAssertEqual(dupes.count, 2)
        XCTAssertEqual(dupes[1].exists, true)

        // Windows candidates spend only the budget left after Unix paths.
        let mixed = detector.detect(in: ((0..<(limit + 5)).map { "C:\\build\\out\\module-\($0)\\artifact.dll" } + [realFile.path]).joined(separator: "\n"))
        XCTAssertEqual(mixed.count, limit + 6)
        let unixResult = try XCTUnwrap(mixed.last)
        XCTAssertEqual(unixResult.path, realFile.path)
        XCTAssertEqual(unixResult.exists, true)
        XCTAssertEqual(unixResult.confidence, 0.9, accuracy: 0.001)
        XCTAssertEqual(mixed.dropLast().filter { $0.exists != nil }.count, limit - 1)
        XCTAssertNil(mixed[limit].exists)
    }
}
