import Foundation
import XCTest
import PastaCore
@testable import PastaDetectors

/// Extraction of embedded values from mixed clipboard content: what becomes a
/// child item, when an entry is "mixed", and the bounds on how much is saved.
final class ContentExtractionTests: XCTestCase {
    private let detector = ContentTypeDetector()

    func testAllSupportedValueTypesExtractInsideOtherContent() throws {
        let jwt = DetectorTestSupport.makeJWT(header: #"{"alg":"HS256","typ":"JWT"}"#, payload: #"{"sub":"test"}"#, signature: "signature")
        let examples: [(ContentType, String)] = [
            (.email, "person@example.com"), (.url, "https://example.com"),
            (.phoneNumber, "+1 (415) 555-2671"), (.ipAddress, "192.168.1.7"),
            (.uuid, "550e8400-e29b-41d4-a716-446655440000"),
            (.hash, "5d41402abc4b2a76b9719d911017c592"),
            (.jwt, jwt), (.filePath, "/tmp/pasta-report.txt"),
            (.color, "#ff8800"), (.macAddress, "00:1A:2B:3C:4D:5E"),
            (.creditCard, "4111-1111-1111-1111"),
            (.iban, "GB82 WEST 1234 5698 7654 32"),
            (.envVar, #"export GREETING="hello world""#),
            (.shellCommand, "git status")
        ]
        for (type, value) in examples {
            let content = "Detected values:\n\(value)\nEnd of values."
            let output = detector.detect(in: content, primaryTypeOverride: .prose)
            let item = try XCTUnwrap(output.extractedItems.first { $0.contentType == type }, "\(type): \(output.extractedItems.map(\.contentType))")
            XCTAssertEqual(item.content, value, type.rawValue)
            XCTAssertTrue(MetadataParser.typeMask(for: output.metadataJSON).contains(type), type.rawValue)
            let preview = MetadataParser.extractValues(for: type, from: output.metadataJSON, content: content)
            XCTAssertTrue(preview.contains { $0.value == value }, type.rawValue)
        }
    }

    func testCompositionTable() {
        let contact = "Contact a@example.com or visit https://example.com."
        let cases: [(name: String, input: String, primary: ContentType?, expectedPrimary: ContentType?, items: [String], mixed: Bool?)] = [
            ("short email list", "a@example.com\nb@example.com", nil, nil, ["a@example.com", "b@example.com"], false),
            ("short text with link", "See https://example.com", nil, .url, ["https://example.com"], true),
            ("repeated email dedupes", "Email a@example.com or a@example.com", nil, nil, ["a@example.com"], nil),
            ("json keeps code type", #"{"website":"https://example.com","contact":"a@example.com"}"#, .code, .code,
             ["https://example.com", "a@example.com"], true),
            ("single url", "https://example.com", nil, nil, [], false),
            ("single url with path", "https://example.com/a/path", nil, nil, [], false),
            ("single email", "a@example.com", nil, nil, [], false),
            ("single encoded url", "https%3A%2F%2Fexample.com", nil, nil, [], false),
        ] + [ContentType.text, .prose, .code, .url].map {
            ("override \($0.rawValue)", contact, $0, $0, ["a@example.com", "https://example.com"], true)
        }
        for c in cases {
            let output = detector.detect(in: c.input, primaryTypeOverride: c.primary)
            if let expected = c.expectedPrimary { XCTAssertEqual(output.primaryType, expected, "case \(c.name)") }
            XCTAssertEqual(Set(output.extractedItems.map(\.content)), Set(c.items), "case \(c.name)")
            XCTAssertEqual(output.extractedItems.count, c.items.count, "case \(c.name)")
            if let mixed = c.mixed {
                XCTAssertEqual(MetadataParser.typeMask(for: output.metadataJSON).contains(.mixed), mixed, "case \(c.name)")
            }
        }

        let list = detector.detect(in: "a@example.com\nb@example.com")
        let entry = ClipboardEntry(content: "", contentType: list.primaryType, metadata: list.metadataJSON)
        XCTAssertFalse(entry.isMixedContent)
        XCTAssertTrue(entry.hasMultipleDetectedItems)

        let envList = detector.detect(in: "FIRST=one\n\nSECOND=two")
        XCTAssertFalse(MetadataParser.typeMask(for: envList.metadataJSON).contains(.mixed), "env grouping alone is not mixed")
        XCTAssertTrue(MetadataParser.typeMask(for: envList.metadataJSON).contains(.multipleItems))
    }

    func testEmbeddedCodeAndEnvironmentAssignments() throws {
        let fenced = detector.detect(in: "Example:\n```python\nprint(\"https://example.com\")\n```", primaryTypeOverride: .code)
        let snippet = try XCTUnwrap(fenced.extractedItems.first { $0.contentType == .code })
        XCTAssertEqual(snippet.content, #"print("https://example.com")"#)
        XCTAssertTrue(fenced.extractedItems.contains { $0.contentType == .url && $0.content == "https://example.com" })
        let snippetMeta = DetectorTestSupport.parseJSON(snippet.metadataJSON)
        XCTAssertEqual((snippetMeta?["code"] as? [[String: Any]])?.first?["language"] as? String, "python")
        XCTAssertEqual(MetadataParser.extractValues(for: .code, from: snippet.metadataJSON, content: snippet.content).first?.value, snippet.content)

        let assignment = #"export WEBSITE="https://example.com""#
        let single = detector.detect(in: assignment)
        XCTAssertTrue(single.extractedItems.contains { $0.contentType == .url && $0.content == "https://example.com" })
        XCTAssertFalse(single.extractedItems.contains { $0.content == assignment })
        let block = detector.detect(in: "Notes:\nFIRST=one\nSECOND=two\nEnd.")
        XCTAssertTrue(block.extractedItems.contains { $0.contentType == .envVarBlock && $0.content == "FIRST=one\nSECOND=two" })
        XCTAssertEqual(block.extractedItems.filter { $0.contentType == .envVar }.count, 2)
    }

    func testExtractionLimitsAndAnalysisTruncation() throws {
        let emails150 = (0..<150).map { "person\($0)@example.com" }.joined(separator: "\n")
        for limit in [1, 25, 100, 250, 0] {
            let output = detector.detect(in: emails150, extractionConfiguration: try .init(maximumSavedItems: limit))
            XCTAssertEqual(output.extractedItems.count, limit == 0 ? 150 : min(limit, 150), "limit \(limit)")
            let composition = try XCTUnwrap(DetectorTestSupport.composition(output.metadataJSON), "limit \(limit)")
            XCTAssertEqual(composition["extractionLimit"] as? Int, limit)
            XCTAssertEqual(MetadataParser.extractAllValues(from: output.metadataJSON).filter { $0.type == .email }.count, 150,
                           "preview values stay uncapped at limit \(limit)")
        }

        let defaultCap = detector.detect(in: (0..<125).map { "person\($0)@example.com" }.joined(separator: "\n"))
        XCTAssertEqual(defaultCap.extractedItems.count, 100)
        let defaultSummary = try XCTUnwrap(DetectorTestSupport.composition(defaultCap.metadataJSON))
        XCTAssertEqual(defaultSummary["itemCount"] as? Int, 125)
        XCTAssertEqual(defaultSummary["extractionLimit"] as? Int, 100)
        XCTAssertEqual(defaultSummary["isMixed"] as? Bool, false)
        XCTAssertEqual(MetadataParser.extractValues(for: .email, from: defaultCap.metadataJSON).count, 125)

        let truncated = detector.detect(in: "See https://example.com " + String(repeating: "word ", count: 8_000))
        XCTAssertEqual(DetectorTestSupport.composition(truncated.metadataJSON)?["analysisTruncated"] as? Bool, true)
        XCTAssertEqual(truncated.extractedItems.first?.content, "https://example.com")

        // Save-all still bounds analysis (b@ lies past the window) and dedupes.
        let saveAll = detector.detect(in: "a@example.com\na@example.com\n" + String(repeating: "word ", count: 6_000) + "\nb@example.com",
                                      extractionConfiguration: try .init(maximumSavedItems: 0))
        XCTAssertEqual(saveAll.extractedItems.filter { $0.contentType == .email }.map(\.content), ["a@example.com"])
        XCTAssertEqual(DetectorTestSupport.composition(saveAll.metadataJSON)?["analysisTruncated"] as? Bool, true)

        let colors = (0..<1_200).map { String(format: "#%06x", 0xAB0000 + $0) }
        let manyColors = detector.detect(in: colors.joined(separator: "\n"), extractionConfiguration: try .init(maximumSavedItems: 0))
        XCTAssertEqual(Set(manyColors.extractedItems.filter { $0.contentType == .color }.map(\.content)), Set(colors))

        // Excluded API keys must not consume configured slots.
        var rules = DetectorConfiguration.default
        var rule = rules.rule(for: .apiKey)
        rule.useAdvancedPatterns = true
        rule.advancedPatterns = ["TOKEN_[A-Z]+"]
        rules.setRule(rule, for: .apiKey)
        let skipped = detector.detect(in: "TOKEN_ALPHA\nTOKEN_BETA\n#ff8800\n#00ff00", configuration: rules,
                                      extractionConfiguration: try .init(maximumSavedItems: 2), skipAPIKeysForExtraction: true)
        XCTAssertEqual(skipped.extractedItems.map(\.contentType), [.color, .color])
    }

    func testCardMetadataIsMaskedButExactCopyWorksIncludingDecodedContent() throws {
        let card = "4111-1111-1111-1111"
        let content = "Card for a test: \(card)"
        for input in [content, Data(content.utf8).base64EncodedString()] {
            let output = detector.detect(in: input)
            let child = try XCTUnwrap(output.extractedItems.first { $0.contentType == .creditCard })
            XCTAssertEqual(child.content, card)
            let childMetadata = try XCTUnwrap(child.metadataJSON)
            XCTAssertFalse(childMetadata.contains(card))
            XCTAssertFalse(childMetadata.contains("4111111111111111"))
            let preview = try XCTUnwrap(MetadataParser.extractValues(for: .creditCard, from: output.metadataJSON, content: input).first)
            XCTAssertEqual(preview.value, card)
            XCTAssertEqual(preview.displayValue, "**** **** **** 1111")
            XCTAssertEqual(MetadataParser.extractValues(for: .creditCard, from: childMetadata, content: child.content).first?.value, card)
        }
    }
}
