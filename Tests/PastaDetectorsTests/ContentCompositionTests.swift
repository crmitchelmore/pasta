import XCTest
import PastaCore
@testable import PastaDetectors

final class ContentCompositionTests: XCTestCase {
    private let detector = ContentTypeDetector()

    func testShortEmailListExtractsEveryAddressWithoutBecomingMixed() throws {
        let output = detector.detect(in: "a@example.com\nb@example.com")
        XCTAssertEqual(output.extractedItems.map(\.content), ["a@example.com", "b@example.com"])
        let entry = ClipboardEntry(content: "", contentType: output.primaryType, metadata: output.metadataJSON)
        XCTAssertFalse(entry.isMixedContent)
        XCTAssertTrue(entry.hasMultipleDetectedItems)
    }

    func testShortTextWithLinkIsMixedEvenWhenPrimaryHeuristicSaysURL() {
        let output = detector.detect(in: "See https://example.com")
        XCTAssertEqual(output.primaryType, .url)
        XCTAssertEqual(output.extractedItems.map(\.content), ["https://example.com"])
        XCTAssertTrue(MetadataParser.typeMask(for: output.metadataJSON).contains(.mixed))
    }

    func testEveryPrimaryOverridePreservesEmailAndURLExtraction() {
        let content = "Contact a@example.com or visit https://example.com."
        for primary in [ContentType.text, .prose, .code, .url] {
            let output = detector.detect(in: content, primaryTypeOverride: primary)
            XCTAssertEqual(output.primaryType, primary)
            XCTAssertEqual(Set(output.extractedItems.map(\.content)), ["a@example.com", "https://example.com"])
            XCTAssertTrue(MetadataParser.typeMask(for: output.metadataJSON).contains(.mixed))
        }
    }

    func testJSONKeepsCodePreviewTypeAndExtractsLinks() {
        let output = detector.detect(in: #"{"website":"https://example.com","contact":"a@example.com"}"#, primaryTypeOverride: .code)
        XCTAssertEqual(output.primaryType, .code)
        XCTAssertEqual(Set(output.extractedItems.map(\.contentType)), [.url, .email])
        XCTAssertTrue(MetadataParser.typeMask(for: output.metadataJSON).contains(.mixed))
    }

    func testSingleValuesAreNotDuplicatedOrMarkedMixed() {
        for content in ["https://example.com", "https://example.com/a/path", "a@example.com",
                        "https%3A%2F%2Fexample.com"] {
            let output = detector.detect(in: content)
            XCTAssertTrue(output.extractedItems.isEmpty, content)
            XCTAssertFalse(MetadataParser.typeMask(for: output.metadataJSON).contains(.mixed), content)
        }
    }

    func testRepeatedEmailProducesOneChild() {
        let output = detector.detect(in: "Email a@example.com or a@example.com")
        XCTAssertEqual(output.extractedItems.map(\.content), ["a@example.com"])
    }

    func testExtractionCapIsExplicitAndMetadataRetainsRemainingValues() throws {
        let content = (0..<125).map { "person\($0)@example.com" }.joined(separator: "\n")
        let output = detector.detect(in: content)
        XCTAssertEqual(output.extractedItems.count, 100)
        let metadata = try XCTUnwrap(output.metadataJSON)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(object["composition"] as? [String: Any])
        XCTAssertEqual(summary["itemCount"] as? Int, 125)
        XCTAssertEqual(summary["extractionLimit"] as? Int, 100)
        XCTAssertEqual(summary["isMixed"] as? Bool, false)
        XCTAssertEqual(MetadataParser.extractValues(for: .email, from: metadata).count, 125)
    }

    func testAnalysisTruncationIsRecordedWithoutDroppingOriginalContent() throws {
        let content = "See https://example.com " + String(repeating: "word ", count: 8_000)
        let output = detector.detect(in: content)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.metadataJSON).utf8)) as? [String: Any])
        let summary = try XCTUnwrap(object["composition"] as? [String: Any])
        XCTAssertEqual(summary["analysisTruncated"] as? Bool, true)
        XCTAssertEqual(output.extractedItems.first?.content, "https://example.com")
    }
}
