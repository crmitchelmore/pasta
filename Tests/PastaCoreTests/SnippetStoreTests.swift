import Foundation
import XCTest
@testable import PastaCore

final class SnippetStoreTests: XCTestCase {
    /// Snippet CRUD, search, ordering and JSON import against a real database, and
    /// rendering that reads the latest saved template and history at activation.
    func testSnippetLifecycleSearchImportAndRendering() throws {
        let database = try DatabaseManager.inMemory()
        let store = SnippetStore(database: database)

        let oldDate = Date(timeIntervalSince1970: 100)
        var reply = Snippet(name: "Email reply", content: "Thanks, {clipboard}", keyword: "reply",
                            createdAt: oldDate, updatedAt: oldDate)
        try store.create(reply)
        try store.create(Snippet(name: "Date stamp", content: "{date}", keyword: "ds",
                                 createdAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200)))
        try store.create(Snippet(name: "Misc", content: "Hello world", keyword: nil,
                                 createdAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300)))
        try store.create(Snippet(name: "Percent", content: "literal", keyword: "%_",
                                 createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 50)))

        XCTAssertEqual(try store.list().map(\.name), ["Misc", "Date stamp", "Email reply", "Percent"])
        let fetched = try XCTUnwrap(try store.get(id: reply.id))
        XCTAssertEqual([fetched.name, fetched.content, fetched.keyword], ["Email reply", "Thanks, {clipboard}", "reply"])

        XCTAssertEqual(try store.find(matching: "email").map(\.name), ["Email reply"])
        XCTAssertEqual(try store.find(matching: "ds").map(\.name), ["Date stamp"])
        XCTAssertEqual(try store.find(matching: "world").map(\.name), ["Misc"])
        XCTAssertEqual(try store.find(matching: "%_").map(\.name), ["Percent"], "LIKE wildcards are literal")
        XCTAssertEqual(try store.find(matching: "   ").count, 4)

        XCTAssertEqual(SnippetCommands.searchQuery("SNIPPET greeting"), "greeting")
        XCTAssertEqual(SnippetCommands.searchQuery("snippets"), "")
        XCTAssertNil(SnippetCommands.searchQuery("snippetish"))
        XCTAssertEqual(SnippetCommands.commands(for: try store.find(matching: "REPLY")).count, 1)

        // Rendering reads the template saved after the command list was built.
        reply.name = "Reply"
        reply.content = "{clipboard:2}|{clipboard:1}|{clipboard}|{cursor}👨‍👩‍👧‍👦é"
        let updated = try store.update(reply)
        XCTAssertGreaterThan(updated.updatedAt, oldDate)
        XCTAssertEqual(try store.list().first?.name, "Reply")
        try database.insert(ClipboardEntry(content: "older", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try database.insert(ClipboardEntry(content: "latest", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))
        let rendered = try XCTUnwrap(SnippetRenderer(database: database).render(id: reply.id, clipboardText: "current"))
        XCTAssertEqual(rendered.text, "older|latest|current|👨‍👩‍👧‍👦é")
        XCTAssertEqual(rendered.cursorMoveCount, 2)

        XCTAssertTrue(try store.delete(id: reply.id))
        XCTAssertNil(try store.get(id: reply.id))
        XCTAssertFalse(try store.delete(id: reply.id))
        XCTAssertNil(try SnippetRenderer(database: database).render(id: reply.id, clipboardText: nil))

        // JSON export round-trips and import updates by id instead of duplicating.
        let id = UUID()
        try store.create(Snippet(id: id, name: "v1", content: "old"))
        let exported = try SnippetJSONIO.decode(SnippetJSONIO.encode([
            Snippet(id: id, name: "v2", content: "new", keyword: "v"),
            Snippet(name: "fresh", content: "{date:yyyy-MM-dd}")
        ]))
        XCTAssertEqual(exported.map(\.name), ["v2", "fresh"])
        XCTAssertEqual(exported[0].keyword, "v")
        XCTAssertEqual(exported[1].content, "{date:yyyy-MM-dd}")
        let countBeforeImport = try store.list().count
        let summary = try SnippetJSONIO.importSnippets(exported, into: store)
        XCTAssertEqual([summary.inserted, summary.updated, summary.total], [1, 1, 2])
        XCTAssertEqual(try store.get(id: id)?.content, "new")
        XCTAssertEqual(try store.list().count, countBeforeImport + 1)
    }
}
