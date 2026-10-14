import Foundation
import XCTest
import PastaCore
@testable import PastaDetectors

final class ExpandedExtractionTests: XCTestCase {
    private let detector = ContentTypeDetector()

    func testAllSupportedValueTypesExtractInsideOtherContent() throws {
        let jwt = [#"{"alg":"HS256","typ":"JWT"}"#, #"{"sub":"test"}"#, "signature"].map {
            Data($0.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }.joined(separator: ".")
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

    func testAPIKeyExclusionDoesNotConsumeConfiguredSlots() throws {
        var rules = DetectorConfiguration.default
        var rule = rules.rule(for: .apiKey)
        rule.useAdvancedPatterns = true
        rule.advancedPatterns = ["TOKEN_[A-Z]+"]
        rules.setRule(rule, for: .apiKey)
        let content = "TOKEN_ALPHA\nTOKEN_BETA\n#ff8800\n#00ff00"
        let output = detector.detect(in: content, configuration: rules,
                                     extractionConfiguration: try .init(maximumSavedItems: 2),
                                     skipAPIKeysForExtraction: true)
        XCTAssertEqual(output.extractedItems.count, 2)
        XCTAssertTrue(output.extractedItems.allSatisfy { $0.contentType == .color })
    }

    func testConfiguredAndAllItemLimitsRetainUncappedPreviewValues() throws {
        let content = (0..<150).map { "person\($0)@example.com" }.joined(separator: "\n")
        for limit in [1, 25, 100, 250, 0] {
            let output = detector.detect(in: content, extractionConfiguration: try .init(maximumSavedItems: limit))
            XCTAssertEqual(output.extractedItems.count, limit == 0 ? 150 : min(limit, 150))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.metadataJSON).utf8)) as? [String: Any])
            let composition = try XCTUnwrap(object["composition"] as? [String: Any])
            XCTAssertEqual(composition["extractionLimit"] as? Int, limit)
            XCTAssertEqual(MetadataParser.extractAllValues(from: output.metadataJSON).filter { $0.type == .email }.count, 150)
        }
    }

    func testFencedCodeRetainsLanguageAndDoesNotSuppressEmbeddedURLs() throws {
        let content = """
        Example:
        ```python
        print("https://example.com")
        ```
        """
        let output = detector.detect(in: content, primaryTypeOverride: .code)
        let snippet = try XCTUnwrap(output.extractedItems.first { $0.contentType == .code })
        XCTAssertEqual(snippet.content, #"print("https://example.com")"#)
        XCTAssertTrue(output.extractedItems.contains { $0.contentType == .url && $0.content == "https://example.com" })
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(snippet.metadataJSON).utf8)) as? [String: Any])
        XCTAssertEqual((metadata["code"] as? [[String: Any]])?.first?["language"] as? String, "python")
        XCTAssertEqual(MetadataParser.extractValues(for: .code, from: snippet.metadataJSON, content: snippet.content).first?.value, snippet.content)
    }

    func testEnvironmentAssignmentPreservesQuotesAndEmbeddedValues() throws {
        let content = #"export WEBSITE="https://example.com""#
        let output = detector.detect(in: content)
        XCTAssertTrue(output.extractedItems.contains { $0.contentType == .url && $0.content == "https://example.com" })
        XCTAssertFalse(output.extractedItems.contains { $0.content == content })
        let block = detector.detect(in: "Notes:\nFIRST=one\nSECOND=two\nEnd.")
        XCTAssertTrue(block.extractedItems.contains { $0.contentType == .envVarBlock && $0.content == "FIRST=one\nSECOND=two" })
        XCTAssertEqual(block.extractedItems.filter { $0.contentType == .envVar }.count, 2)
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

    func testSaveAllStillBoundsAnalysisAndDeduplicatesValues() throws {
        let content = "a@example.com\na@example.com\n" + String(repeating: "word ", count: 6_000) + "\nb@example.com"
        let output = detector.detect(in: content, extractionConfiguration: try .init(maximumSavedItems: 0))
        XCTAssertEqual(output.extractedItems.filter { $0.contentType == .email }.map(\.content), ["a@example.com"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.metadataJSON).utf8)) as? [String: Any])
        XCTAssertEqual((object["composition"] as? [String: Any])?["analysisTruncated"] as? Bool, true)
    }

    func testSaveAllStoresThousandsOfNonEmailValues() throws {
        let colors = (0..<1_200).map { String(format: "#%06x", 0xAB0000 + $0) }
        let output = detector.detect(in: colors.joined(separator: "\n"),
                                     extractionConfiguration: try .init(maximumSavedItems: 0))
        XCTAssertEqual(Set(output.extractedItems.filter { $0.contentType == .color }.map(\.content)), Set(colors))
    }

    func testEnvironmentListsDoNotBecomeMixedJustBecauseOfBlockGrouping() {
        let output = detector.detect(in: "FIRST=one\n\nSECOND=two")
        XCTAssertFalse(MetadataParser.typeMask(for: output.metadataJSON).contains(.mixed))
        XCTAssertTrue(MetadataParser.typeMask(for: output.metadataJSON).contains(.multipleItems))
    }
}
