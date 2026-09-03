import Foundation
import GRDB
import XCTest

import PastaUI
@testable import PastaCore

/// Mirrors a real upgrade: a user's on-disk database left at an old schema by
/// a previous release, reopened by the current `DatabaseManager` (which runs
/// the pending migrations, including the `contentTypeMask` backfill), then
/// used for the things the panel does on launch.
final class LegacyDatabaseMigrationTests: XCTestCase {
    private var env: E2ETempEnvironment!

    override func setUpWithError() throws {
        try super.setUpWithError()
        env = try E2ETempEnvironment(name: "migration")
    }

    override func tearDownWithError() throws {
        env.destroy()
        env = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// One legacy row's expected post-migration state.
    private struct SeededRow {
        let id: UUID
        let content: String
        let contentType: ContentType
        let metadata: String?
        let expectedMask: ContentTypeMask
        let timestamp: Date
    }

    private enum LegacyKind: CaseIterable {
        case plain, email, url, mixed, envBlock, envSingle, apiKey, filePath, malformedJSON, emptyArrays, nullMetadata, unicode

        func row(index: Int) -> SeededRow {
            let id = UUID()
            let timestamp = Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 7)
            switch self {
            case .plain:
                return SeededRow(id: id, content: "plain note \(index)", contentType: .text, metadata: nil, expectedMask: [], timestamp: timestamp)
            case .email:
                return SeededRow(
                    id: id, content: "user\(index)@example.com", contentType: .email,
                    metadata: #"{"emails":[{"email":"user\#(index)@example.com","confidence":0.95}]}"#,
                    expectedMask: [.email], timestamp: timestamp
                )
            case .url:
                return SeededRow(
                    id: id, content: "https://example.com/page/\(index)", contentType: .url,
                    metadata: #"{"urls":[{"url":"https://example.com/page/\#(index)","domain":"example.com","confidence":0.9}]}"#,
                    expectedMask: [.url], timestamp: timestamp
                )
            case .mixed:
                return SeededRow(
                    id: id, content: "host 10.0.\(index % 250).7 owner ops\(index)@example.com sha 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", contentType: .prose,
                    metadata: #"{"ipAddresses":[{"address":"10.0.\#(index % 250).7","version":"v4"}],"emails":[{"email":"ops\#(index)@example.com"}],"hashes":[{"hash":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","kind":"sha256"}],"prose":{"wordCount":6}}"#,
                    expectedMask: [.ipAddress, .email, .hash], timestamp: timestamp
                )
            case .envBlock:
                return SeededRow(
                    id: id, content: "A=1\nB=2 (\(index))", contentType: .envVarBlock,
                    metadata: #"{"env":{"isBlock":true,"vars":[{"key":"A","value":"1"},{"key":"B","value":"2"}]}}"#,
                    expectedMask: [.envVar, .envVarBlock], timestamp: timestamp
                )
            case .envSingle:
                return SeededRow(
                    id: id, content: "TOKEN_\(index)=abc", contentType: .envVar,
                    metadata: #"{"env":{"isBlock":false,"vars":[{"key":"TOKEN_\#(index)","value":"abc"}]}}"#,
                    expectedMask: [.envVar], timestamp: timestamp
                )
            case .apiKey:
                return SeededRow(
                    id: id, content: "sk-live-\(index)-0123456789abcdef", contentType: .apiKey,
                    metadata: #"{"apiKeys":[{"key":"sk-live-\#(index)-0123456789abcdef","provider":"OpenAI","confidence":0.8}]}"#,
                    expectedMask: [.apiKey], timestamp: timestamp
                )
            case .filePath:
                return SeededRow(
                    id: id, content: "/Users/me/Documents/file-\(index).txt", contentType: .filePath,
                    metadata: #"{"filePaths":[{"path":"/Users/me/Documents/file-\#(index).txt","filename":"file-\#(index).txt","fileType":"document"}]}"#,
                    expectedMask: [.filePath], timestamp: timestamp
                )
            case .malformedJSON:
                return SeededRow(id: id, content: "broken meta \(index)", contentType: .text, metadata: "{\"emails\": [", expectedMask: [], timestamp: timestamp)
            case .emptyArrays:
                return SeededRow(id: id, content: "empty meta \(index)", contentType: .text, metadata: #"{"emails":[],"urls":[],"hashes":[]}"#, expectedMask: [], timestamp: timestamp)
            case .nullMetadata:
                return SeededRow(id: id, content: "no meta \(index)", contentType: .text, metadata: nil, expectedMask: [], timestamp: timestamp)
            case .unicode:
                return SeededRow(id: id, content: "café résumé naïve \(index) 🍝", contentType: .text, metadata: nil, expectedMask: [], timestamp: timestamp)
            }
        }
    }

    private func makeRows(count: Int) -> [SeededRow] {
        let kinds = LegacyKind.allCases
        return (0..<count).map { kinds[$0 % kinds.count].row(index: $0) }
    }

    /// Builds the database file at the schema `upTo` produced, seeding rows
    /// with raw SQL against that schema's columns, and closes it again so the
    /// current code reopens a cold file exactly as it would on a user's Mac.
    private func writeLegacyDatabase(upTo migration: String, rows: [SeededRow], columns: [String]) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        try autoreleasepool {
            let pool = try DatabasePool(path: env.databaseURL.path, configuration: config)
            try DatabaseManager.migrator.migrate(pool, upTo: migration)

            try pool.write { db in
                let actual = Set(try db.columns(in: ClipboardEntry.databaseTableName).map(\.name))
                XCTAssertEqual(actual, Set(columns), "precondition: fixture schema must match the legacy migration '\(migration)'")
                XCTAssertFalse(actual.contains("contentTypeMask"), "precondition: legacy schema must predate the mask column")

                let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
                let statement = try db.makeStatement(
                    sql: "INSERT INTO clipboard_entries (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
                )
                for row in rows {
                    var values: [DatabaseValueConvertible?] = []
                    for column in columns {
                        switch column {
                        case "id": values.append(row.id.uuidString)
                        case "content": values.append(row.content)
                        case "contentType": values.append(row.contentType.rawValue)
                        case "rawData": values.append(nil)
                        case "imagePath": values.append(nil)
                        case "timestamp": values.append(row.timestamp)
                        case "copyCount": values.append(1)
                        case "sourceApp": values.append("com.legacy.App")
                        case "metadata": values.append(row.metadata)
                        case "contentHash": values.append(ClipboardEntry.sha256Hex(row.content))
                        case "parentEntryId": values.append(nil)
                        case "isSynced": values.append(true)
                        case "isPinned": values.append(false)
                        default: XCTFail("fixture has no value for column \(column)")
                        }
                    }
                    try statement.execute(arguments: StatementArguments(values))
                }
            }
            try pool.close()
        }
    }

    private static let preMaskColumns = [
        "id", "content", "contentType", "rawData", "imagePath", "timestamp", "copyCount",
        "sourceApp", "metadata", "contentHash", "parentEntryId", "isSynced", "isPinned",
    ]

    private static let originalColumns = [
        "id", "content", "contentType", "rawData", "imagePath", "timestamp", "copyCount",
        "sourceApp", "metadata", "contentHash",
    ]

    // MARK: - Shared assertions

    private func assertUpgradedDatabaseWorks(_ db: DatabaseManager, rows: [SeededRow], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try db.countEntries(), rows.count, file: file, line: line)

        // Every row is readable and its mask was backfilled from its metadata.
        let byID = Dictionary(uniqueKeysWithValues: try db.fetchAll().map { ($0.id, $0) })
        XCTAssertEqual(byID.count, rows.count, file: file, line: line)
        for row in rows {
            let stored = try XCTUnwrap(byID[row.id], "row \(row.content) missing after upgrade", file: file, line: line)
            XCTAssertEqual(stored.contentTypeMask, row.expectedMask, "mask for \(row.content)", file: file, line: line)
            XCTAssertEqual(stored.contentType, row.contentType, file: file, line: line)
            XCTAssertEqual(stored.metadata, row.metadata, file: file, line: line)
            XCTAssertEqual(stored.timestamp.timeIntervalSince1970, row.timestamp.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
        }

        // The raw column agrees with the model for every row (not just the sample).
        let mismatches: Int = try db.dbWriter.read { conn in
            let cursor = try Row.fetchCursor(conn, sql: "SELECT metadata, contentTypeMask FROM clipboard_entries")
            var count = 0
            while let r = try cursor.next() {
                let expected = MetadataParser.typeMask(for: r["metadata"] as String?).rawValue
                if expected != (r["contentTypeMask"] as Int) { count += 1 }
            }
            return count
        }
        XCTAssertEqual(mismatches, 0, "every backfilled mask must match the parser", file: file, line: line)

        // Backfill must not have dirtied sync state.
        XCTAssertEqual(try db.unsyncedCount(), 0, file: file, line: line)

        // The launch-time keyset walk covers the whole legacy library in order.
        var seen: [UUID] = []
        var cursor: DatabaseManager.HistoryCursor?
        repeat {
            let page = try db.fetchHistoryPage(after: cursor, limit: 64)
            seen.append(contentsOf: page.entries.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(seen.count, rows.count, file: file, line: line)
        XCTAssertEqual(Set(seen).count, rows.count, "keyset walk must not repeat rows", file: file, line: line)
        XCTAssertEqual(seen.first, rows.max(by: { $0.timestamp < $1.timestamp })?.id, file: file, line: line)

        // FTS was (re)built over legacy content, diacritics folded.
        let search = SearchService(database: db)
        XCTAssertFalse(try search.search(query: "cafe resume").isEmpty, "legacy unicode rows must be searchable", file: file, line: line)
        let emails = try search.search(query: "user", contentType: .email, limit: 500)
        XCTAssertEqual(emails.count, rows.filter { $0.contentType == .email }.count, file: file, line: line)

        // Type counts the sidebar shows come straight off the mask column.
        let expectedURLs = rows.filter { $0.expectedMask.contains(.url) }.count
        let urlRows: Int = try db.dbWriter.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM clipboard_entries WHERE contentTypeMask & ? != 0", arguments: [ContentTypeMask.url.rawValue]) ?? 0
        }
        XCTAssertEqual(urlRows, expectedURLs, file: file, line: line)

        // New writes land in the upgraded schema with a mask, and dedupe against legacy hashes.
        let fresh = ClipboardEntry(content: "post-upgrade a@b.co", contentType: .text, metadata: #"{"emails":[{"email":"a@b.co"}]}"#)
        try db.insert(fresh)
        XCTAssertEqual(try db.fetch(id: fresh.id)?.contentTypeMask, [.email], file: file, line: line)
        let legacyDuplicate = ClipboardEntry(content: rows[0].content, contentType: .text)
        try db.insert(legacyDuplicate, deduplicate: true)
        XCTAssertEqual(try db.countEntries(), rows.count + 1, "re-copying legacy content must fold into the legacy row", file: file, line: line)
        XCTAssertEqual(try db.fetch(id: rows[0].id)?.copyCount, 2, file: file, line: line)

        // Rows render.
        for entry in try db.fetchRecent(limit: 40) {
            _ = ClipboardRowData(from: entry)
        }
    }

    // MARK: - Tests

    func testPreMaskDatabaseWithHundredsOfRowsIsBackfilledAndUsable() throws {
        let rows = makeRows(count: 480)
        try writeLegacyDatabase(upTo: "addUnsyncedIndex", rows: rows, columns: Self.preMaskColumns)

        let db = try env.openDatabase()
        let columns = try db.dbWriter.read { try $0.columns(in: ClipboardEntry.databaseTableName).map(\.name) }
        XCTAssertTrue(columns.contains("contentTypeMask"))
        try assertUpgradedDatabaseWorks(db, rows: rows)
    }

    func testOriginalReleaseSchemaUpgradesThroughEveryMigration() throws {
        // The very first schema: no parentEntryId / isSynced / isPinned / mask,
        // and the original (contentType-polluted) FTS table.
        let rows = makeRows(count: 300)
        try writeLegacyDatabase(upTo: "createClipboardEntriesFTS", rows: rows, columns: Self.originalColumns)

        let db = try env.openDatabase()
        try assertUpgradedDatabaseWorks(db, rows: rows)

        // Columns added by later migrations carry their defaults on the legacy rows.
        let legacyIDs = Set(rows.map(\.id))
        let fetched = try db.fetchAll().filter { legacyIDs.contains($0.id) }
        XCTAssertEqual(fetched.count, rows.count)
        XCTAssertTrue(fetched.allSatisfy { $0.parentEntryId == nil && !$0.isPinned })
        XCTAssertTrue(fetched.allSatisfy(\.isSynced), "backfillIsSynced marks pre-sync rows as synced")
    }

    func testReopeningAnUpgradedDatabaseIsIdempotent() throws {
        let rows = makeRows(count: 120)
        try writeLegacyDatabase(upTo: "addUnsyncedIndex", rows: rows, columns: Self.preMaskColumns)

        try autoreleasepool {
            let first = try env.openDatabase()
            XCTAssertEqual(try first.countEntries(), rows.count)
        }

        let second = try env.openDatabase()
        XCTAssertEqual(try second.countEntries(), rows.count)
        let appliedTwice: Bool = try second.dbWriter.read { db in
            try DatabaseManager.migrator.hasCompletedMigrations(db)
        }
        XCTAssertTrue(appliedTwice)
        try assertUpgradedDatabaseWorks(second, rows: rows)
    }
}
