import GRDB
import XCTest
@testable import PastaCore

final class ContentCompositionTests: XCTestCase {
    func testMixedSearchFiltersBeforeLimitingAndPreservesBaseType() throws {
        let database = try DatabaseManager.inMemory()
        let metadata = try ContentComposition.metadata(nil, content: "Contact a@example.com about launch",
            values: [(.email, "a@example.com")], analysisTruncated: false)
        let mixed = ClipboardEntry(content: "Contact a@example.com about launch", contentType: .prose, metadata: metadata)
        try database.insert(mixed, deduplicate: false)
        for index in 0..<210 {
            try database.insert(ClipboardEntry(content: "launch \(index)", contentType: .text), deduplicate: false)
        }
        let matches = try SearchService(database: database).search(query: "launch", limit: 1, mixedOnly: true)
        XCTAssertEqual(matches.map(\.entry.id), [mixed.id])
        XCTAssertEqual(matches.first?.entry.contentType, .prose)
        XCTAssertEqual(try database.searchFTS(query: "launch", contentType: .prose, mixedOnly: true).map(\.id), [mixed.id])
        let child = ClipboardEntry(content: "launch child", contentType: .text, metadata: metadata, parentEntryId: mixed.id)
        try database.insert(child, deduplicate: false)
        XCTAssertFalse(child.isMixedContent)
        XCTAssertEqual(try database.searchFTS(query: "launch", contentType: nil, mixedOnly: true).map(\.id), [mixed.id])
    }

    func testCompositionSurvivesExportAndRecomputesOnMetadataChange() throws {
        let metadata = try ContentComposition.metadata(nil, content: "Contact a@example.com",
            values: [(.email, "a@example.com")], analysisTruncated: false)
        var entry = ClipboardEntry(content: "Contact a@example.com", contentType: .text, metadata: metadata)
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertTrue(decoded.isMixedContent)
        XCTAssertEqual(decoded.contentType, .text)
        entry.metadata = nil
        XCTAssertFalse(entry.isMixedContent)
    }

    func testMigrationBackfillsParentsWithoutReclassifyingOrCreatingChildren() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "classificationCloudDeletions")
        let database = DatabaseManager(dbWriter: queue)
        let entry = ClipboardEntry(content: "Contact a@example.com for details.", contentType: .prose,
            metadata: #"{"emails":[{"email":"a@example.com"}]}"#, isSynced: true, isPinned: true, cloudSyncAllowed: false)
        try database.insert(entry, deduplicate: false)
        try DatabaseManager.migrator.migrate(queue)
        let updated = try XCTUnwrap(database.fetch(id: entry.id))
        XCTAssertTrue(updated.isMixedContent)
        XCTAssertEqual(updated.contentType, .prose)
        XCTAssertEqual(updated.content, entry.content)
        XCTAssertTrue(updated.isPinned)
        XCTAssertFalse(updated.cloudSyncAllowed)
        XCTAssertFalse(updated.isSynced)
        XCTAssertTrue(try database.fetchExtractedEntries(parentId: entry.id).isEmpty)
    }

    func testHistoricalSingleAndMultipleValuesRemainDistinctFromMixed() throws {
        let single = #"{"emails":[{"email":"a@example.com"}]}"#
        XCTAssertEqual(try ContentComposition.backfilledMetadata(single, content: "a@example.com"), single)
        let list = #"{"emails":[{"email":"a@example.com"},{"email":"b@example.com"}]}"#
        let metadata = try ContentComposition.backfilledMetadata(list, content: "a@example.com\nb@example.com")
        let mask = MetadataParser.typeMask(for: metadata)
        XCTAssertFalse(mask.contains(.mixed))
        XCTAssertTrue(mask.contains(.multipleItems))
    }
}
