import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class ContentTypeMaskTests: XCTestCase {
    // MARK: - Derivation

    func testTypeMaskCoversEveryExtractableType() {
        let metadata = """
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
          "shellCommands":[{"command":"ls -la","executable":"ls"}]
        }
        """

        let mask = MetadataParser.typeMask(for: metadata)

        for type in MetadataParser.extractableTypes {
            XCTAssertTrue(mask.contains(type), "\(type) should be set")
            XCTAssertTrue(MetadataParser.containsType(type, in: metadata), "\(type) via containsType")
        }
        XCTAssertFalse(mask.contains(.text))
        XCTAssertFalse(mask.contains(.image))
    }

    func testTypeMaskDistinguishesEnvVarFromEnvVarBlock() {
        let single = MetadataParser.typeMask(for: #"{"env":{"isBlock":false,"vars":[{"key":"A","value":"1"}]}}"#)
        XCTAssertTrue(single.contains(.envVar))
        XCTAssertFalse(single.contains(.envVarBlock))

        let block = MetadataParser.typeMask(for: #"{"env":{"isBlock":true,"vars":[]}}"#)
        XCTAssertTrue(block.contains(.envVar))
        XCTAssertTrue(block.contains(.envVarBlock))
    }

    func testTypeMaskIgnoresEmptyArraysNilAndMalformedMetadata() {
        XCTAssertEqual(MetadataParser.typeMask(for: nil), [])
        XCTAssertEqual(MetadataParser.typeMask(for: ""), [])
        XCTAssertEqual(MetadataParser.typeMask(for: "not json {"), [])
        XCTAssertEqual(MetadataParser.typeMask(for: "[1,2,3]"), [])
        XCTAssertEqual(MetadataParser.typeMask(for: #"{"emails":[],"urls":[]}"#), [])
        // A key mentioned inside a value must not count: the old substring
        // prefilter would have matched this, the parse must not.
        XCTAssertEqual(MetadataParser.typeMask(for: #"{"note":"\"emails\" appear here"}"#), [])
    }

    func testTypeMaskBitLayoutIsStable() {
        // These raw values are persisted in the `contentTypeMask` column.
        XCTAssertEqual(ContentTypeMask.email.rawValue, 1 << 0)
        XCTAssertEqual(ContentTypeMask.url.rawValue, 1 << 1)
        XCTAssertEqual(ContentTypeMask.phoneNumber.rawValue, 1 << 2)
        XCTAssertEqual(ContentTypeMask.ipAddress.rawValue, 1 << 3)
        XCTAssertEqual(ContentTypeMask.uuid.rawValue, 1 << 4)
        XCTAssertEqual(ContentTypeMask.hash.rawValue, 1 << 5)
        XCTAssertEqual(ContentTypeMask.apiKey.rawValue, 1 << 6)
        XCTAssertEqual(ContentTypeMask.jwt.rawValue, 1 << 7)
        XCTAssertEqual(ContentTypeMask.envVar.rawValue, 1 << 8)
        XCTAssertEqual(ContentTypeMask.envVarBlock.rawValue, 1 << 9)
        XCTAssertEqual(ContentTypeMask.filePath.rawValue, 1 << 10)
        XCTAssertEqual(ContentTypeMask.shellCommand.rawValue, 1 << 11)
        XCTAssertNil(ContentTypeMask(.text))
    }

    // MARK: - ClipboardEntry

    func testEntryDerivesMaskOnInitAndWhenMetadataChanges() {
        var entry = ClipboardEntry(
            content: "mail a@b.com",
            contentType: .text,
            metadata: #"{"emails":[{"email":"a@b.com"}]}"#
        )
        XCTAssertEqual(entry.contentTypeMask, [.email])
        XCTAssertTrue(entry.containsType(.email))
        XCTAssertFalse(entry.containsType(.url))

        entry.metadata = #"{"urls":[{"url":"https://x.y"}]}"#
        XCTAssertEqual(entry.contentTypeMask, [.url])

        entry.metadata = nil
        XCTAssertEqual(entry.contentTypeMask, [])
    }

    func testEntryContainsTypeStillHonoursPrimaryType() {
        let entry = ClipboardEntry(content: "https://x.y", contentType: .url)
        XCTAssertEqual(entry.contentTypeMask, [])
        XCTAssertTrue(entry.containsType(.url))
    }

    func testDecodingLegacyJSONWithoutMaskDerivesIt() throws {
        // Shape of a pre-mask ImportService export.
        let legacy = """
        {
          "id": "3C7A6A4A-45CB-4E7C-9CE9-C72BEF825C4F",
          "content": "x",
          "contentType": "text",
          "timestamp": 1000,
          "copyCount": 1,
          "metadata": "{\\"hashes\\":[{\\"hash\\":\\"abc\\"}]}",
          "isSynced": false,
          "isPinned": false
        }
        """
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.contentTypeMask, [.hash])

        // And a round trip through the current encoder keeps the stored value.
        let data = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(ClipboardEntry.self, from: data)
        XCTAssertEqual(again.contentTypeMask, [.hash])
    }

    // MARK: - Persistence

    func testInsertPersistsMaskAndFetchReadsItBack() throws {
        let db = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(
            content: "ssh root@10.0.0.1",
            contentType: .shellCommand,
            metadata: #"{"shellCommands":[{"command":"ssh"}],"ipAddresses":[{"address":"10.0.0.1"}]}"#
        )
        try db.insert(entry)
        try db.insertBatch([
            ClipboardEntry(content: "k", contentType: .text, metadata: #"{"apiKeys":[{"key":"sk"}]}"#)
        ])

        let fetched = try db.fetchRecent(limit: 10)
        XCTAssertEqual(fetched.count, 2)
        let shell = try XCTUnwrap(fetched.first { $0.id == entry.id })
        XCTAssertEqual(shell.contentTypeMask, [.shellCommand, .ipAddress])
        let key = try XCTUnwrap(fetched.first { $0.id != entry.id })
        XCTAssertEqual(key.contentTypeMask, [.apiKey])

        let raw: Int? = try db.dbWriter.read { conn in
            try Int.fetchOne(conn, sql: "SELECT contentTypeMask FROM clipboard_entries WHERE id = ?", arguments: [entry.id.uuidString])
        }
        XCTAssertEqual(raw, ContentTypeMask([.shellCommand, .ipAddress]).rawValue)
    }

    func testReclassificationRewritesMask() throws {
        let db = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "x", contentType: .text, metadata: #"{"emails":[{"email":"a@b.com"}]}"#)
        try db.insert(entry)

        _ = try db.applyReclassificationChunk(
            updates: [.init(entryID: entry.id, contentType: .url, metadata: #"{"urls":[{"url":"https://a.b"}]}"#)],
            parentIDs: [entry.id],
            extractedEntries: [
                ClipboardEntry(content: "https://a.b", contentType: .url, metadata: #"{"urls":[{"url":"https://a.b"}]}"#, parentEntryId: entry.id)
            ]
        )

        let updated = try XCTUnwrap(try db.fetch(id: entry.id))
        XCTAssertEqual(updated.contentTypeMask, [.url])
        let children = try db.fetchExtractedEntries(parentId: entry.id)
        XCTAssertEqual(children.map(\.contentTypeMask), [[.url]])
    }

    // MARK: - Migration backfill

    func testAddContentTypeMaskMigrationBackfillsExistingRows() throws {
        let queue = try DatabaseQueue()
        // Bring the schema to the state just before the mask column existed.
        try DatabaseManager.migrator.migrate(queue, upTo: "addUnsyncedIndex")

        let withEmail = UUID(), withEnvBlock = UUID(), noMeta = UUID(), badMeta = UUID(), emptyArrays = UUID()
        try queue.write { db in
            let columns = try db.columns(in: ClipboardEntry.databaseTableName).map(\.name)
            XCTAssertFalse(columns.contains("contentTypeMask"), "precondition: column must not exist yet")

            func seed(_ id: UUID, _ metadata: String?) throws {
                try db.execute(
                    sql: """
                    INSERT INTO clipboard_entries
                    (id, content, contentType, timestamp, copyCount, metadata, contentHash, isSynced, isPinned)
                    VALUES (?, ?, 'text', ?, 1, ?, ?, 1, 0)
                    """,
                    arguments: [id.uuidString, id.uuidString, Date(), metadata, id.uuidString]
                )
            }
            try seed(withEmail, #"{"emails":[{"email":"a@b.com"}],"urls":[{"url":"https://a.b"}]}"#)
            try seed(withEnvBlock, #"{"env":{"isBlock":true,"vars":[{"key":"A","value":"1"}]}}"#)
            try seed(noMeta, nil)
            try seed(badMeta, "{not json")
            try seed(emptyArrays, #"{"emails":[],"hashes":[]}"#)
        }

        try DatabaseManager.migrator.migrate(queue)

        let db = DatabaseManager(dbWriter: queue)
        XCTAssertEqual(try db.fetch(id: withEmail)?.contentTypeMask, [.email, .url])
        XCTAssertEqual(try db.fetch(id: withEnvBlock)?.contentTypeMask, [.envVar, .envVarBlock])
        XCTAssertEqual(try db.fetch(id: noMeta)?.contentTypeMask, [])
        XCTAssertEqual(try db.fetch(id: badMeta)?.contentTypeMask, [])
        XCTAssertEqual(try db.fetch(id: emptyArrays)?.contentTypeMask, [])

        // Backfill must not have marked anything unsynced or touched FTS
        // (the update trigger is scoped to `content`).
        XCTAssertEqual(try db.unsyncedCount(), 0)
    }
}
