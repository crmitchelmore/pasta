import Foundation
import GRDB

extension DatabaseManager {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createClipboardEntries") { db in
            try db.create(table: ClipboardEntry.databaseTableName) { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("content", .text).notNull()
                t.column("contentType", .text).notNull()
                t.column("rawData", .blob)
                t.column("imagePath", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("copyCount", .integer).notNull().defaults(to: 1)
                t.column("sourceApp", .text)
                t.column("metadata", .text)
                t.column("contentHash", .text).notNull()
            }

            try db.create(index: "idx_clipboard_entries_timestamp", on: ClipboardEntry.databaseTableName, columns: ["timestamp"])
            try db.create(index: "idx_clipboard_entries_contentType", on: ClipboardEntry.databaseTableName, columns: ["contentType"])
            try db.create(index: "idx_clipboard_entries_contentHash", on: ClipboardEntry.databaseTableName, columns: ["contentHash"])
            // Common query: WHERE contentType = ? ORDER BY timestamp DESC LIMIT ?
            try db.create(index: "idx_clipboard_entries_contentType_timestamp", on: ClipboardEntry.databaseTableName, columns: ["contentType", "timestamp"])
        }

        migrator.registerMigration("createClipboardEntriesFTS") { db in
            try db.execute(sql: """
            CREATE VIRTUAL TABLE clipboard_entries_fts USING fts5(
                content,
                contentType,
                content='clipboard_entries',
                content_rowid='rowid'
            );
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(rowid, content, contentType)
                VALUES (new.rowid, new.content, new.contentType);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content, contentType)
                VALUES('delete', old.rowid, old.content, old.contentType);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_au AFTER UPDATE ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content, contentType)
                VALUES('delete', old.rowid, old.content, old.contentType);
                INSERT INTO clipboard_entries_fts(rowid, content, contentType)
                VALUES (new.rowid, new.content, new.contentType);
            END;
            """)

            // Index any existing rows (important for existing on-disk databases).
            try db.execute(sql: "INSERT INTO clipboard_entries_fts(clipboard_entries_fts) VALUES('rebuild');")
        }

        migrator.registerMigration("addParentEntryId") { db in
            // Add parentEntryId column for extracted entries to reference their source
            try db.alter(table: ClipboardEntry.databaseTableName) { t in
                t.add(column: "parentEntryId", .text)
            }
            // Index for efficient lookups of children by parent
            try db.create(index: "idx_clipboard_entries_parentEntryId", on: ClipboardEntry.databaseTableName, columns: ["parentEntryId"])
        }

        migrator.registerMigration("addIsSynced") { db in
            try db.alter(table: ClipboardEntry.databaseTableName) { t in
                t.add(column: "isSynced", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("backfillIsSynced") { db in
            // All entries that existed before isSynced was added were already
            // bulk-pushed to CloudKit — mark them as synced.
            try db.execute(
                sql: "UPDATE \(ClipboardEntry.databaseTableName) SET isSynced = 1 WHERE isSynced = 0"
            )
        }

        migrator.registerMigration("rebuildFTSIndexV2") { db in
            // The original FTS table indexed `contentType` as a tokenised column,
            // which polluted ranking — searching "url" matched every URL by
            // metadata text. We also want diacritic-folding so "café" matches
            // "cafe". Rebuild with `content` only and the
            // `unicode61 remove_diacritics 2` tokenizer.
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_entries_au;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_entries_ad;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_entries_ai;")
            try db.execute(sql: "DROP TABLE IF EXISTS clipboard_entries_fts;")

            try db.execute(sql: """
            CREATE VIRTUAL TABLE clipboard_entries_fts USING fts5(
                content,
                content='clipboard_entries',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_ai AFTER INSERT ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(rowid, content)
                VALUES (new.rowid, new.content);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_ad AFTER DELETE ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content)
                VALUES('delete', old.rowid, old.content);
            END;
            """)

            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_au AFTER UPDATE ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content)
                VALUES('delete', old.rowid, old.content);
                INSERT INTO clipboard_entries_fts(rowid, content)
                VALUES (new.rowid, new.content);
            END;
            """)

            try db.execute(sql: "INSERT INTO clipboard_entries_fts(clipboard_entries_fts) VALUES('rebuild');")
        }

        migrator.registerMigration("createSnippets") { db in
            try db.create(table: Snippet.databaseTableName) { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("name", .text).notNull()
                t.column("content", .text).notNull()
                t.column("keyword", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_snippets_keyword", on: Snippet.databaseTableName, columns: ["keyword"])
            try db.create(index: "idx_snippets_updatedAt", on: Snippet.databaseTableName, columns: ["updatedAt"])
        }

        migrator.registerMigration("addIsPinned") { db in
            try db.alter(table: ClipboardEntry.databaseTableName) { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(
                index: "idx_clipboard_entries_isPinned",
                on: ClipboardEntry.databaseTableName,
                columns: ["isPinned"]
            )
        }

        migrator.registerMigration("ftsUpdateTriggerOnContentOnly") { db in
            // The update trigger fired on *any* column change — pin toggles,
            // markSynced batches, dedup copyCount/timestamp bumps and
            // reclassification all paid for a full FTS delete + re-tokenise of
            // the entry's content, inside the write lock. Only `content` is
            // indexed, so scope the trigger to that column.
            try db.execute(sql: "DROP TRIGGER IF EXISTS clipboard_entries_au;")
            try db.execute(sql: """
            CREATE TRIGGER clipboard_entries_au AFTER UPDATE OF content ON clipboard_entries BEGIN
                INSERT INTO clipboard_entries_fts(clipboard_entries_fts, rowid, content)
                VALUES('delete', old.rowid, old.content);
                INSERT INTO clipboard_entries_fts(rowid, content)
                VALUES (new.rowid, new.content);
            END;
            """)
        }

        migrator.registerMigration("addUnsyncedIndex") { db in
            // Partial index so `fetchUnsynced` stays cheap on a fully-synced
            // library: it only contains the rows still waiting to be pushed.
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_clipboard_entries_unsynced
            ON \(ClipboardEntry.databaseTableName)(timestamp)
            WHERE isSynced = 0;
            """)
        }

        migrator.registerMigration("addContentTypeMask") { db in
            // Bitmask of the extractable content types present in `metadata`
            // (see `ContentTypeMask`). Persisting it means the panel's per-type
            // counts and filters are an integer test per row instead of a
            // JSON parse / substring scan of every metadata string on each
            // clipboard change.
            try db.alter(table: ClipboardEntry.databaseTableName) { t in
                t.add(column: "contentTypeMask", .integer).notNull().defaults(to: 0)
            }

            // One-off backfill from the metadata that existing rows already
            // carry, using the same parser new inserts use. Read everything
            // first (streaming; only (rowid, mask) pairs are retained) and
            // update afterwards so the cursor never walks a table it is
            // mutating. The FTS update trigger is scoped to `content`, so this
            // does not re-tokenise anything.
            var masks: [(rowID: Int64, mask: Int)] = []
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT rowid, metadata FROM \(ClipboardEntry.databaseTableName) WHERE metadata IS NOT NULL"
            )
            while let row = try rows.next() {
                let mask = MetadataParser.typeMask(for: row["metadata"] as String?)
                guard !mask.isEmpty else { continue }
                masks.append((row["rowid"] as Int64, mask.rawValue))
            }

            let update = try db.makeStatement(
                sql: "UPDATE \(ClipboardEntry.databaseTableName) SET contentTypeMask = ? WHERE rowid = ?"
            )
            for (rowID, mask) in masks {
                try update.execute(arguments: [mask, rowID])
            }
        }

        return migrator
    }
}
