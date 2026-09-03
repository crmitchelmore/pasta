import AppKit
import Foundation
import SwiftUI
import XCTest

import PastaDetectors
@testable import PastaCore
@testable import PastaUI

/// For a representative sample of clipboard payloads: detectors → persisted
/// type/metadata/mask → the row model and the preview panel the user sees.
/// Every stage runs on the value the previous one actually produced, so a
/// metadata shape the preview cannot read fails here.
@MainActor
final class DetectorMetadataPreviewTests: XCTestCase {
    private struct Sample {
        let name: String
        let content: String
        let expectedType: ContentType
        /// Bits the mask must carry; the detectors may legitimately add more
        /// (a URL path also reads as a file path, a temp dir contains a UUID).
        let requiredMask: ContentTypeMask
        let metadataKey: String
    }

    private var env: E2ETempEnvironment!
    private var database: DatabaseManager!
    private var pipeline: E2ECapturePipeline!

    override func setUpWithError() throws {
        try super.setUpWithError()
        env = try E2ETempEnvironment(name: "preview")
        database = try env.openDatabase()
        pipeline = E2ECapturePipeline(
            database: database,
            imageStorage: try env.openImageStorage(),
            detector: ContentTypeDetector()
        )
    }

    override func tearDownWithError() throws {
        pipeline = nil
        database = nil
        env.destroy()
        env = nil
        try super.tearDownWithError()
    }

    private func samples() throws -> [Sample] {
        let realFile = env.root.appendingPathComponent("report.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: realFile)

        return [
            Sample(
                name: "url",
                content: "https://developer.apple.com/documentation/swift",
                expectedType: .url, requiredMask: [.url], metadataKey: "urls"
            ),
            Sample(
                name: "email",
                content: "someone@example.org",
                expectedType: .email, requiredMask: [.email], metadataKey: "emails"
            ),
            Sample(
                name: "jwt",
                content: e2eSampleJWT(),
                expectedType: .jwt, requiredMask: [.jwt], metadataKey: "jwt"
            ),
            Sample(
                name: "colour",
                content: "#FF8800",
                expectedType: .color, requiredMask: [], metadataKey: "colors"
            ),
            Sample(
                name: "code",
                content: """
                import Foundation

                struct Greeter {
                    let name: String

                    func greet() -> String {
                        return "Hello, \\(name)!"
                    }
                }
                """,
                expectedType: .code, requiredMask: [], metadataKey: "code"
            ),
            Sample(
                name: "prose",
                content: """
                The quick brown fox jumps over the lazy dog. This sentence exists purely so the \
                prose detector has enough ordinary English words to be confident, and so nothing \
                in it looks like a URL, an address, or a snippet of code.
                """,
                expectedType: .prose, requiredMask: [], metadataKey: "prose"
            ),
            Sample(
                name: "file path",
                content: realFile.path,
                expectedType: .filePath, requiredMask: [.filePath], metadataKey: "filePaths"
            ),
        ]
    }

    // MARK: - Stage assertions

    func testEachSamplePersistsTheTypeMetadataAndMaskTheDetectorsProduced() throws {
        for sample in try samples() {
            let captured = ClipboardEntry(content: sample.content, contentType: .text, sourceApp: "com.example.Editor")
            let result = try pipeline.ingest(captured)
            let stored = try XCTUnwrap(database.fetch(id: captured.id), "\(sample.name): row missing")

            XCTAssertEqual(stored.contentType, sample.expectedType, "\(sample.name): primary type")
            XCTAssertEqual(stored.contentType, result.primary.contentType, "\(sample.name): stored type must equal detected type")
            XCTAssertEqual(stored.metadata, result.primary.metadata, "\(sample.name): metadata must round-trip through SQLite")

            let metadata = try XCTUnwrap(e2eJSONDictionary(stored.metadata), "\(sample.name): metadata must be a JSON object")
            XCTAssertNotNil(metadata[sample.metadataKey], "\(sample.name): metadata must carry '\(sample.metadataKey)'")

            XCTAssertTrue(stored.contentTypeMask.isSuperset(of: sample.requiredMask), "\(sample.name): persisted mask \(stored.contentTypeMask) lacks \(sample.requiredMask)")
            XCTAssertEqual(stored.contentTypeMask, MetadataParser.typeMask(for: stored.metadata), "\(sample.name): mask derived from stored metadata")
        }
        XCTAssertEqual(try database.fetchPrimaryEntries().count, 7)
    }

    func testEachSampleDrivesRowDataAndPreviewPanelWithoutTrapping() throws {
        var rendered = 0
        for sample in try samples() {
            let captured = ClipboardEntry(content: sample.content, contentType: .text, sourceApp: "com.example.Editor")
            try pipeline.ingest(captured)
            let stored = try XCTUnwrap(database.fetch(id: captured.id))

            let row = ClipboardRowData(from: stored)
            XCTAssertEqual(row.id, stored.id)
            XCTAssertEqual(row.contentType, sample.expectedType, "\(sample.name): row type")
            XCTAssertFalse(row.previewText.isEmpty, "\(sample.name): row preview")
            XCTAssertFalse(row.singleLinePreview.contains("\n"), "\(sample.name): single-line preview")
            XCTAssertFalse(row.mainPanelMetadata.isEmpty)
            XCTAssertEqual(row.quickSearchMetadataSegments.first, sample.expectedType.displayTitle)
            XCTAssertEqual(row.contentLength, sample.content.utf8.count)

            let cached = ClipboardRowModelCache().rows(for: [stored])
            XCTAssertEqual(cached, [row], "\(sample.name): the model cache must produce the same row")

            let image = E2ERender.snapshot(PreviewPanelView(entry: stored, onCopy: { _ in }))
            XCTAssertNotNil(image, "\(sample.name): preview panel must render")
            rendered += 1
        }
        XCTAssertEqual(rendered, 7)
    }

    // MARK: - Per-type derivations the preview relies on

    func testColourMetadataDrivesTheRowSwatch() throws {
        let captured = ClipboardEntry(content: "rgb(18, 52, 86)", contentType: .text)
        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .color)

        let swatch = try XCTUnwrap(ClipboardRowData(from: stored).swatchColor, "swatch must be parsed from persisted colour metadata")
        XCTAssertEqual(swatch.red, 18)
        XCTAssertEqual(swatch.green, 52)
        XCTAssertEqual(swatch.blue, 86)
        XCTAssertEqual(swatch.alpha, 1.0, accuracy: 0.001)

        // A colour row without metadata falls back to parsing hex content.
        let bare = ClipboardEntry(content: "#0A0B0C", contentType: .color)
        let fallback = try XCTUnwrap(ClipboardRowData(from: bare).swatchColor)
        XCTAssertEqual([fallback.red, fallback.green, fallback.blue], [0x0A, 0x0B, 0x0C])
    }

    func testJWTMetadataExposesDecodedHeaderAndPayload() throws {
        let captured = ClipboardEntry(content: e2eSampleJWT(), contentType: .text)
        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .jwt)

        let jwts = try XCTUnwrap(e2eJSONDictionary(stored.metadata)?["jwt"] as? [[String: Any]])
        let first = try XCTUnwrap(jwts.first)
        XCTAssertEqual(first["token"] as? String, e2eSampleJWT())
        XCTAssertTrue((first["headerJSON"] as? String)?.contains("HS256") == true)
        XCTAssertTrue((first["payloadJSON"] as? String)?.contains("Pasta E2E") == true)
        XCTAssertEqual((first["claims"] as? [String: Any])?["iss"] as? String, "pasta.test")
        XCTAssertEqual(first["isExpired"] as? Bool, false)

        XCTAssertTrue(stored.containsType(.jwt))
        XCTAssertEqual(stored.extractedValues(for: .jwt).map(\.value), [e2eSampleJWT()])
    }

    func testCodeMetadataNamesTheLanguage() throws {
        let captured = ClipboardEntry(
            content: """
            import SwiftUI
            struct ContentView: View {
                var body: some View { Text("Hi") }
            }
            """,
            contentType: .text
        )
        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .code)

        let code = try XCTUnwrap(e2eJSONDictionary(stored.metadata)?["code"] as? [[String: Any]])
        XCTAssertEqual(code.first?["language"] as? String, CodeLanguage.swift.rawValue)
        XCTAssertNotNil(E2ERender.snapshot(PreviewPanelView(entry: stored)))
    }

    func testFilePathMetadataRecordsExistenceAndTypeForPreview() throws {
        let file = env.root.appendingPathComponent("slides.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: file)
        let captured = ClipboardEntry(content: file.path, contentType: .filePath)
        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))
        XCTAssertEqual(stored.contentType, .filePath)

        let paths = try XCTUnwrap(e2eJSONDictionary(stored.metadata)?["filePaths"] as? [[String: Any]])
        let first = try XCTUnwrap(paths.first)
        XCTAssertEqual(first["path"] as? String, file.path)
        XCTAssertEqual(first["filename"] as? String, "slides.pdf")
        XCTAssertEqual(first["exists"] as? Bool, true)
        XCTAssertEqual(first["fileType"] as? String, FilePathDetector.FileType.document.rawValue)
        XCTAssertNotNil(E2ERender.snapshot(PreviewPanelView(entry: stored)))
    }

    func testMixedContentExposesExtractedValuesForTheDetectedItemsSection() throws {
        let captured = ClipboardEntry(
            content: "Staging is 10.0.0.42 (id 550e8400-e29b-41d4-a716-446655440000); page ops@example.com or open https://status.example.com",
            contentType: .text
        )
        try pipeline.ingest(captured)
        let stored = try XCTUnwrap(database.fetch(id: captured.id))

        for type in [ContentType.ipAddress, .uuid, .email, .url] {
            XCTAssertTrue(stored.contentTypeMask.contains(try XCTUnwrap(ContentTypeMask(type))), "mask must include \(type)")
        }
        let values = stored.allExtractedValues
        XCTAssertTrue(Set(values.map(\.type)).isSuperset(of: [.ipAddress, .uuid, .email, .url]), "got \(values.map(\.type))")
        XCTAssertTrue(values.contains { $0.value == "550e8400-e29b-41d4-a716-446655440000" })
        XCTAssertEqual(MetadataParser.extractAllValues(from: stored.metadata, limit: 2).count, 2)

        XCTAssertNotNil(E2ERender.snapshot(PreviewPanelView(entry: stored)))
    }

    func testPreviewSurvivesHostileMetadataAndEmptyState() throws {
        let hostile = [
            ClipboardEntry(content: "#abc", contentType: .color, metadata: #"{"colors":"not-an-array"}"#),
            ClipboardEntry(content: "x.y.z", contentType: .jwt, metadata: #"{"jwt":[{"claims":"oops"}]}"#),
            ClipboardEntry(content: "/nowhere", contentType: .filePath, metadata: #"{"filePaths":[{}]}"#),
            ClipboardEntry(content: "fn()", contentType: .code, metadata: "{not json"),
            ClipboardEntry(content: "", contentType: .image, imagePath: "/definitely/missing.dat"),
            ClipboardEntry(content: String(repeating: "long ", count: 5_000), contentType: .text, metadata: nil),
        ]
        for entry in hostile {
            try database.insert(entry, deduplicate: false)
            let stored = try XCTUnwrap(database.fetch(id: entry.id))
            _ = ClipboardRowData(from: stored)
            XCTAssertNotNil(E2ERender.snapshot(PreviewPanelView(entry: stored)), "\(entry.contentType) with hostile metadata must still render")
        }
        XCTAssertNotNil(E2ERender.snapshot(PreviewPanelView(entry: nil, isListEmpty: true)))
        XCTAssertNotNil(E2ERender.snapshot(PreviewPanelView(entry: nil, isListEmpty: false)))
    }
}
