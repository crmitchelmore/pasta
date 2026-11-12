import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class ContentTypeMaskTests: XCTestCase {
    func testMetadataDerivesMaskCompositionAndCopyValues() throws {
        let everything = """
        {
          "emails":[{"email":"a@b.com"}],
          "urls":[{"url":"https://example.com","domain":"example.com"}],
          "phoneNumbers":[{"number":"+1 555 0100"}],
          "ipAddresses":[{"address":"10.0.0.1","version":"v4"}],
          "uuids":[{"uuid":"3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F"}],
          "hashes":[{"hash":"abc","kind":"md5"}],
          "apiKeys":[{"key":"sk-1","provider":"OpenAI"}],
          "jwt":[{"token":"a.b.c"}],
          "env":{"isBlock":true,"vars":[{"key":"A","value":"1"}]},
          "filePaths":[{"path":"/tmp/x"}],
          "shellCommands":[{"command":"ls -la","executable":"ls"}],
          "colors":[{"raw":"#ff8800"}],
          "macAddresses":[{"raw":"00:1A:2B:3C:4D:5E"}],
          "creditCards":[{"masked":"**** 1111","location":0,"length":16}],
          "ibans":[{"iban":"GB82WEST12345698765432"}],
          "code":[{"language":"python","location":0,"length":12}]
        }
        """
        let mask = MetadataParser.typeMask(for: everything)
        for type in MetadataParser.extractableTypes {
            XCTAssertTrue(mask.contains(type), "\(type) should be set")
            XCTAssertTrue(MetadataParser.containsType(type, in: everything), "\(type) via containsType")
        }
        XCTAssertFalse(mask.contains(.text))
        XCTAssertNil(ContentTypeMask(.text))

        let cases: [(metadata: String?, expected: ContentTypeMask)] = [
            (#"{"env":{"isBlock":false,"vars":[{"key":"A","value":"1"}]}}"#, [.envVar]),
            (#"{"env":{"isBlock":true,"vars":[]}}"#, [.envVar, .envVarBlock]),
            (nil, []),
            ("", []),
            ("not json {", []),
            ("[1,2,3]", []),
            (#"{"emails":[],"urls":[]}"#, []),
            // A key mentioned inside a value must not count.
            (#"{"note":"\"emails\" appear here"}"#, []),
        ]
        for c in cases {
            XCTAssertEqual(MetadataParser.typeMask(for: c.metadata), c.expected, c.metadata ?? "nil")
        }

        // Entries derive the mask on init and whenever metadata changes, and
        // still honour the primary type.
        var entry = ClipboardEntry(content: "mail a@b.com", contentType: .text, metadata: #"{"emails":[{"email":"a@b.com"}]}"#)
        XCTAssertEqual(entry.contentTypeMask, [.email])
        XCTAssertTrue(entry.containsType(.email))
        XCTAssertFalse(entry.containsType(.url))
        entry.metadata = #"{"urls":[{"url":"https://x.y"}]}"#
        XCTAssertEqual(entry.contentTypeMask, [.url])
        entry.metadata = nil
        XCTAssertEqual(entry.contentTypeMask, [])
        XCTAssertTrue(ClipboardEntry(content: "https://x.y", contentType: .url).containsType(.url))

        // A pre-mask ImportService export derives the mask; round trips keep it.
        let legacy = """
        {"id":"3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F","content":"x","contentType":"text","timestamp":1000,
         "copyCount":1,"metadata":"{\\"hashes\\":[{\\"hash\\":\\"abc\\"}]}","isSynced":false,"isPinned":false}
        """
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.contentTypeMask, [.hash])
        XCTAssertEqual(try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(decoded)).contentTypeMask, [.hash])

        // Mixed composition survives export and is recomputed from metadata.
        let composed = try ContentComposition.metadata(nil, content: "Contact a@example.com",
            values: [(.email, "a@example.com")], analysisTruncated: false)
        var mixed = ClipboardEntry(content: "Contact a@example.com", contentType: .text, metadata: composed)
        let exported = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(mixed))
        XCTAssertTrue(exported.isMixedContent)
        XCTAssertEqual(exported.contentType, .text)
        mixed.metadata = nil
        XCTAssertFalse(mixed.isMixedContent)

        // Historical single values stay untouched; lists become multipleItems, not mixed.
        let single = #"{"emails":[{"email":"a@example.com"}]}"#
        XCTAssertEqual(try ContentComposition.backfilledMetadata(single, content: "a@example.com"), single)
        let list = #"{"emails":[{"email":"a@example.com"},{"email":"b@example.com"}]}"#
        let listMask = MetadataParser.typeMask(for: try ContentComposition.backfilledMetadata(list, content: "a@example.com\nb@example.com"))
        XCTAssertFalse(listMask.contains(.mixed))
        XCTAssertTrue(listMask.contains(.multipleItems))

        // Invalid source ranges cannot produce masked or unrelated copy values.
        for location in [-1, Int.max, 100] {
            let metadata = #"{"creditCards":[{"masked":"**** **** **** 1111","location":\#(location),"length":16}]}"#
            XCTAssertTrue(MetadataParser.extractValues(for: .creditCard, from: metadata, content: "short").isEmpty)
        }
        XCTAssertTrue(MetadataParser.extractValues(for: .creditCard, from: #"{"creditCards":[{"masked":"**** 1111"}]}"#, content: "short").isEmpty)
    }

    func testPersistedMaskAndFastRowDecoding() throws {
        let db = try DatabaseManager.inMemory()
        let shell = ClipboardEntry(
            content: "ssh root@10.0.0.1", contentType: .shellCommand,
            metadata: #"{"shellCommands":[{"command":"ssh"}],"ipAddresses":[{"address":"10.0.0.1"}]}"#
        )
        try db.insert(shell)
        let raw: Int? = try db.dbWriter.read { conn in
            try Int.fetchOne(conn, sql: "SELECT contentTypeMask FROM clipboard_entries WHERE id = ?", arguments: [shell.id.uuidString])
        }
        XCTAssertEqual(raw, ContentTypeMask([.shellCommand, .ipAddress]).rawValue)

        // Reclassification rewrites the parent's mask and derives the children's.
        let reclassified = ClipboardEntry(content: "x", contentType: .text, metadata: #"{"emails":[{"email":"a@b.com"}]}"#)
        try db.insert(reclassified)
        _ = try db.applyReclassificationChunk(
            updates: [.init(entryID: reclassified.id, contentType: .url, metadata: #"{"urls":[{"url":"https://a.b"}]}"#)],
            parentIDs: [reclassified.id],
            extractedEntries: [
                ClipboardEntry(content: "https://a.b", contentType: .url, metadata: #"{"urls":[{"url":"https://a.b"}]}"#, parentEntryId: reclassified.id)
            ]
        )
        XCTAssertEqual(try db.fetch(id: reclassified.id)?.contentTypeMask, [.url])
        XCTAssertEqual(try db.fetchExtractedEntries(parentId: reclassified.id).map(\.contentTypeMask), [[.url]])

        // `init(row:)` replaces GRDB's synthesized decoding for speed and must
        // decode every stored shape identically.
        let parent = UUID()
        var entries: [ClipboardEntry] = ContentType.allCases.enumerated().map { index, type in
            ClipboardEntry(
                content: "entry \(index) ✓", contentType: type,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) + 0.123),
                copyCount: index + 1, sourceApp: index.isMultiple(of: 2) ? "com.apple.Safari" : nil
            )
        }
        let rich = ClipboardEntry(
            content: "rich", contentType: .text, rawData: Data("{\\rtf1 hello}".utf8),
            imagePath: "/tmp/image.png", sourceApp: "Notes",
            metadata: #"{"urls":[{"url":"https://example.com"}],"emails":[{"email":"a@b.co"}]}"#,
            parentEntryId: parent, isSynced: true, isPinned: true,
            cloudSyncAllowed: false, receivedViaTailnet: true
        )
        entries.append(rich)
        entries.append(ClipboardEntry(content: "", contentType: .image, rawData: Data()))
        _ = try db.insertBatch(entries, deduplicate: false)

        let rows = try db.dbWriter.read { try Row.fetchAll($0, sql: "SELECT rowid, * FROM clipboard_entries") }
        XCTAssertEqual(rows.count, entries.count + 3)
        for row in rows {
            XCTAssertEqual(try ClipboardEntry(row: row), try codableDecode(row))
        }
        let fetchedRich = try XCTUnwrap(db.fetch(id: rich.id))
        XCTAssertEqual(fetchedRich.rawData, rich.rawData)
        XCTAssertEqual(fetchedRich.parentEntryId, parent)
        XCTAssertEqual(fetchedRich.contentTypeMask, [.url, .email])
        XCTAssertTrue(fetchedRich.isPinned && fetchedRich.isSynced && fetchedRich.receivedViaTailnet)
        XCTAssertFalse(fetchedRich.cloudSyncAllowed)

        // Legacy rows without optional columns use the same defaults.
        let legacyID = UUID()
        let legacy: Row = [
            "id": legacyID.uuidString, "content": "legacy", "contentType": "url", "rawData": nil, "imagePath": nil,
            "timestamp": "2024-01-02 03:04:05.678", "copyCount": 3, "sourceApp": nil,
            "metadata": #"{"urls":[{"url":"https://example.com"}]}"#, "parentEntryId": nil, "contentTypeMask": nil,
        ]
        let decoded = try ClipboardEntry(row: legacy)
        XCTAssertEqual(decoded, try codableDecode(legacy))
        XCTAssertEqual(decoded.id, legacyID)
        XCTAssertTrue(decoded.cloudSyncAllowed)
        XCTAssertFalse(decoded.receivedViaTailnet || decoded.isSynced || decoded.isPinned)
        XCTAssertEqual(decoded.contentTypeMask, .url)

        let unknown: Row = [
            "id": UUID().uuidString, "content": "x", "contentType": "hologram",
            "timestamp": "2024-01-02 03:04:05.678", "copyCount": 1,
        ]
        XCTAssertThrowsError(try codableDecode(unknown))
        XCTAssertThrowsError(try ClipboardEntry(row: unknown))
    }

    func testMigrationsBackfillMasksAndCompositionWithoutTouchingSharingState() throws {
        // addContentTypeMask backfills rows written before the column existed.
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "addUnsyncedIndex")
        let withEmail = UUID(), withEnvBlock = UUID(), noMeta = UUID(), badMeta = UUID(), emptyArrays = UUID()
        try queue.write { db in
            XCTAssertFalse(try db.columns(in: ClipboardEntry.databaseTableName).map(\.name).contains("contentTypeMask"))
            for (id, metadata) in [
                (withEmail, #"{"emails":[{"email":"a@b.com"}],"urls":[{"url":"https://a.b"}]}"#),
                (withEnvBlock, #"{"env":{"isBlock":true,"vars":[{"key":"A","value":"1"}]}}"#),
                (noMeta, nil),
                (badMeta, "{not json"),
                (emptyArrays, #"{"emails":[],"hashes":[]}"#),
            ] as [(UUID, String?)] {
                try db.execute(
                    sql: """
                    INSERT INTO clipboard_entries
                    (id, content, contentType, timestamp, copyCount, metadata, contentHash, isSynced, isPinned)
                    VALUES (?, ?, 'text', ?, 1, ?, ?, 1, 0)
                    """,
                    arguments: [id.uuidString, id.uuidString, Date(), metadata, id.uuidString]
                )
            }
        }
        try DatabaseManager.migrator.migrate(queue)
        let db = DatabaseManager(dbWriter: queue)
        XCTAssertEqual(try db.fetch(id: withEmail)?.contentTypeMask, [.email, .url])
        XCTAssertEqual(try db.fetch(id: withEnvBlock)?.contentTypeMask, [.envVar, .envVarBlock])
        for id in [noMeta, badMeta, emptyArrays] {
            XCTAssertEqual(try db.fetch(id: id)?.contentTypeMask, [])
        }
        XCTAssertEqual(try db.unsyncedCount(), 0)

        // Composition backfill marks mixed parents for re-upload without
        // reclassifying them, creating children or changing sharing flags.
        let compositionQueue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(compositionQueue, upTo: "classificationCloudDeletions")
        let compositionDB = DatabaseManager(dbWriter: compositionQueue)
        let prose = ClipboardEntry(content: "Contact a@example.com for details.", contentType: .prose,
            metadata: #"{"emails":[{"email":"a@example.com"}]}"#, isSynced: true, isPinned: true, cloudSyncAllowed: false)
        try compositionDB.insert(prose, deduplicate: false)
        try DatabaseManager.migrator.migrate(compositionQueue)
        let updated = try XCTUnwrap(compositionDB.fetch(id: prose.id))
        XCTAssertTrue(updated.isMixedContent)
        XCTAssertEqual(updated.contentType, .prose)
        XCTAssertEqual(updated.content, prose.content)
        XCTAssertTrue(updated.isPinned)
        XCTAssertFalse(updated.cloudSyncAllowed)
        XCTAssertFalse(updated.isSynced)
        XCTAssertTrue(try compositionDB.fetchExtractedEntries(parentId: prose.id).isEmpty)

        // The expanded mask migration adds colour and MAC bits only.
        let expandedQueue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(expandedQueue, upTo: "backfillContentComposition")
        let expandedDB = DatabaseManager(dbWriter: expandedQueue)
        let metadata = ##"{"colors":[{"raw":"#ff8800"}],"macAddresses":[{"raw":"00:1A:2B:3C:4D:5E"}]}"##
        let hardware = ClipboardEntry(content: "Colors and hardware", contentType: .prose, metadata: metadata,
            isSynced: true, isPinned: true, cloudSyncAllowed: false, receivedViaTailnet: true)
        try expandedDB.insert(hardware, deduplicate: false)
        try expandedQueue.write { db in
            try db.execute(sql: "UPDATE clipboard_entries SET contentTypeMask = 0 WHERE id = ?", arguments: [hardware.id.uuidString])
        }
        try DatabaseManager.migrator.migrate(expandedQueue)
        let expanded = try XCTUnwrap(expandedDB.fetch(id: hardware.id))
        XCTAssertEqual(expanded.contentTypeMask, [.color, .macAddress])
        XCTAssertEqual(expanded.metadata, metadata)
        XCTAssertTrue(expanded.isSynced && expanded.isPinned && expanded.receivedViaTailnet)
        XCTAssertFalse(expanded.cloudSyncAllowed)
    }

    func testContentExtractionConfiguration() throws {
        let suite = "pasta.extraction-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults), .default)
        for limit in [1, 25, 100, 250, 500, 1_000, 0] {
            defaults.set(limit, forKey: ContentExtractionConfiguration.defaultsKey)
            XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults).maximumSavedItems, limit)
        }
        for invalid: Any in [NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true), "all"] {
            defaults.set(invalid, forKey: ContentExtractionConfiguration.defaultsKey)
            XCTAssertEqual(ContentExtractionConfiguration.load(defaults: defaults), .default, "\(invalid)")
        }
        XCTAssertThrowsError(try ContentExtractionConfiguration(maximumSavedItems: -1))
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: 2).limit([1, 2, 3]), [1, 2])
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: 0).limit([1, 2, 3]), [1, 2, 3])
        XCTAssertEqual(ContentExtractionConfiguration.default.reparsePageSize, 100)
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: 0).reparsePageSize, 1)
        XCTAssertEqual(try ContentExtractionConfiguration(maximumSavedItems: Int.max).reparsePageSize, 1)
    }

    private func codableDecode(_ row: Row) throws -> ClipboardEntry {
        try FetchableRecordDecoder().decode(ClipboardEntry.self, from: row)
    }
}
