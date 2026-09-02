import Foundation
import XCTest
@testable import PastaCore

/// The preload's per-type counting pass (`PanelContentView.schedulePreload`),
/// which runs over the whole in-memory history on every clipboard change.
///
/// Both tests count, for each of the 12 extractable types, how many of 50k
/// synthesised entries carry that type in their metadata.
/// `testCountByTypeViaMetadataScanBaseline` is the pre-change approach — one
/// `MetadataParser.containsType` call per (entry, type), i.e. a substring
/// scan of the metadata string per type plus a JSON parse on a hit (the old
/// NSCache in front of it only helped on a warm second pass, and cost an
/// O(len) hash of every metadata string per lookup to do so).
///
/// Measured on an Apple Silicon laptop, 50k entries (90% with metadata),
/// average of 10 `measure` iterations:
///
///   before (metadata scan, cold cache): 1.124 s per pass
///   after  (persisted mask):            0.053 s per pass   (~21x)
///
/// The old NSCache made a warm second pass cheaper, but the preload runs
/// after a *new* copy arrived, so every pass paid at least the 12 substring
/// scans per entry — and the cache itself hashed each full metadata string
/// per lookup and retained up to 20k of them.
final class ContentTypeMaskPerformanceTests: XCTestCase {
    private static let entryCount = 50_000
    private static var entries: [ClipboardEntry] = []

    private static let metadataVariants: [String?] = [
        nil,
        #"{"emails":[{"email":"a@b.com","confidence":0.9}]}"#,
        #"{"urls":[{"url":"https://example.com/some/long/path?q=1","domain":"example.com"}],"emails":[{"email":"x@y.z"}]}"#,
        #"{"phoneNumbers":[{"number":"+1 555 0100"}],"ipAddresses":[{"address":"10.0.0.1","version":"v4"}]}"#,
        #"{"uuids":[{"uuid":"3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F"}],"hashes":[{"hash":"d41d8cd98f00b204e9800998ecf8427e","kind":"md5"}]}"#,
        #"{"apiKeys":[{"key":"sk-live-000000000000","provider":"OpenAI"}],"jwt":[{"token":"aaaa.bbbb.cccc","isExpired":false}]}"#,
        #"{"env":{"isBlock":true,"vars":[{"key":"A","value":"1"},{"key":"B","value":"2"}]}}"#,
        #"{"filePaths":[{"path":"/Users/me/Documents/report.pdf","fileType":"document"}],"shellCommands":[{"command":"ls -la","executable":"ls"}]}"#,
        #"{"code":[{"language":"swift","confidence":0.9}]}"#,
        #"{"customDetectors":[{"name":"Ticket","value":"4821","confidence":0.8}]}"#,
    ]

    override class func setUp() {
        super.setUp()
        entries = (0..<entryCount).map { i in
            ClipboardEntry(
                content: "entry \(i)",
                contentType: .text,
                metadata: metadataVariants[i % metadataVariants.count]
            )
        }
    }

    override class func tearDown() {
        entries = []
        super.tearDown()
    }

    private func expectedCounts() -> [ContentType: Int] {
        var counts: [ContentType: Int] = [:]
        let perCycle = Self.entryCount / Self.metadataVariants.count
        for variant in Self.metadataVariants {
            let mask = MetadataParser.typeMask(for: variant)
            for type in MetadataParser.extractableTypes where mask.contains(type) {
                counts[type, default: 0] += perCycle
            }
        }
        return counts
    }

    func testCountByTypeViaPersistedMask() {
        let entries = Self.entries
        let types = MetadataParser.extractableTypes
        var counts: [ContentType: Int] = [:]

        measure {
            counts = [:]
            for entry in entries {
                let mask = entry.contentTypeMask
                for type in types where mask.contains(type) {
                    counts[type, default: 0] += 1
                }
            }
        }

        XCTAssertEqual(counts, expectedCounts())
    }

    /// Faithful reproduction of the removed `MetadataParser.containsType`
    /// fast path on a cold cache: a substring probe for the type's JSON key,
    /// then one JSON parse per entry (what the NSCache amortised to) on the
    /// first hit.
    func testCountByTypeViaMetadataScanBaseline() {
        let entries = Self.entries
        let types = MetadataParser.extractableTypes
        let markers: [ContentType: String] = [
            .email: "\"emails\"", .url: "\"urls\"", .phoneNumber: "\"phoneNumbers\"",
            .ipAddress: "\"ipAddresses\"", .uuid: "\"uuids\"", .hash: "\"hashes\"",
            .apiKey: "\"apiKeys\"", .jwt: "\"jwt\"", .envVar: "\"env\"", .envVarBlock: "\"env\"",
            .filePath: "\"filePaths\"", .shellCommand: "\"shellCommands\"",
        ]
        var counts: [ContentType: Int] = [:]

        measure {
            counts = [:]
            for entry in entries {
                guard let metadata = entry.metadata else { continue }
                var parsed: ContentTypeMask? = nil
                for type in types {
                    guard metadata.contains(markers[type]!) else { continue }
                    if parsed == nil { parsed = MetadataParser.typeMask(for: metadata) }
                    if parsed!.contains(type) {
                        counts[type, default: 0] += 1
                    }
                }
            }
        }

        XCTAssertEqual(counts, expectedCounts())
    }
}
