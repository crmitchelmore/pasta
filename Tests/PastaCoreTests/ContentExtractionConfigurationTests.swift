import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class ContentExtractionConfigurationTests: XCTestCase {
    func testDefaultsPersistenceAllModeAndInvalidValues() throws {
        let suite = "pasta.extraction-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults), .default)
        for limit in [1, 25, 100, 250, 500, 1_000, 0] {
            defaults.set(limit, forKey: ContentExtractionConfiguration.defaultsKey)
            XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults).maximumSavedItems, limit)
        }
        for invalid in [NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true)] {
            defaults.set(invalid, forKey: ContentExtractionConfiguration.defaultsKey)
            XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults), .default)
        }
        defaults.set("all", forKey: ContentExtractionConfiguration.defaultsKey)
        XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults), .default)
        XCTAssertThrowsError(try ContentExtractionConfiguration(maximumSavedItems: -1))
    }

    func testLimitsAndReparseMemoryBudget() throws {
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: 2).limit([1, 2, 3]), [1, 2])
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: 0).limit([1, 2, 3]), [1, 2, 3])
        XCTAssertEqual(ContentExtractionConfiguration.default.reparsePageSize, 100)
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: 0).reparsePageSize, 1)
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: Int.max).reparsePageSize, 1)
    }

    func testExpandedMaskMigrationPreservesMetadataAndSharingState() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "backfillContentComposition")
        let database = DatabaseManager(dbWriter: queue)
        let metadata = ##"{"colors":[{"raw":"#ff8800"}],"macAddresses":[{"raw":"00:1A:2B:3C:4D:5E"}]}"##
        let entry = ClipboardEntry(content: "Colors and hardware", contentType: .prose, metadata: metadata,
                                   isSynced: true, isPinned: true, cloudSyncAllowed: false, receivedViaTailnet: true)
        try database.insert(entry, deduplicate: false)
        try queue.write { db in
            try db.execute(sql: "UPDATE clipboard_entries SET contentTypeMask = 0 WHERE id = ?", arguments: [entry.id.uuidString])
        }
        try DatabaseManager.migrator.migrate(queue)
        let updated = try XCTUnwrap(database.fetch(id: entry.id))
        XCTAssertEqual(updated.contentTypeMask, [.color, .macAddress])
        XCTAssertEqual(updated.metadata, metadata)
        XCTAssertTrue(updated.isSynced)
        XCTAssertTrue(updated.isPinned)
        XCTAssertFalse(updated.cloudSyncAllowed)
        XCTAssertTrue(updated.receivedViaTailnet)
    }

    func testInvalidSourceRangesCannotProduceMaskedOrUnrelatedCopyValues() {
        for location in [-1, Int.max, 100] {
            let metadata = #"{"creditCards":[{"masked":"**** **** **** 1111","location":\#(location),"length":16}]}"#
            XCTAssertTrue(MetadataParser.extractValues(for: .creditCard, from: metadata, content: "short").isEmpty)
        }
        XCTAssertTrue(MetadataParser.extractValues(for: .creditCard, from: #"{"creditCards":[{"masked":"**** 1111"}]}"#, content: "short").isEmpty)
    }
}
