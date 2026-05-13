import XCTest
import GRDB
@testable import PastaCore

final class SnippetStoreTests: XCTestCase {
    private func makeStore() throws -> SnippetStore {
        let database = try DatabaseManager.inMemory()
        return SnippetStore(database: database)
    }

    func testCreateAndList() throws {
        let store = try makeStore()
        let snippet = Snippet(name: "Greeting", content: "Hello {clipboard}", keyword: "hi")
        _ = try store.create(snippet)

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.name, "Greeting")
        XCTAssertEqual(listed.first?.keyword, "hi")
        XCTAssertEqual(listed.first?.content, "Hello {clipboard}")
    }

    func testGetById() throws {
        let store = try makeStore()
        let snippet = Snippet(name: "S", content: "C")
        _ = try store.create(snippet)
        let found = try store.get(id: snippet.id)
        XCTAssertEqual(found?.id, snippet.id)
        XCTAssertEqual(found?.name, "S")
    }

    func testUpdateBumpsUpdatedAt() throws {
        let store = try makeStore()
        let oldDate = Date(timeIntervalSince1970: 0)
        var snippet = Snippet(
            name: "old",
            content: "x",
            createdAt: oldDate,
            updatedAt: oldDate
        )
        _ = try store.create(snippet)

        snippet.name = "new"
        let updated = try store.update(snippet)
        XCTAssertEqual(updated.name, "new")
        XCTAssertGreaterThan(updated.updatedAt.timeIntervalSince1970, oldDate.timeIntervalSince1970)

        let reloaded = try store.get(id: snippet.id)
        XCTAssertEqual(reloaded?.name, "new")
    }

    func testDelete() throws {
        let store = try makeStore()
        let snippet = Snippet(name: "doomed", content: "x")
        _ = try store.create(snippet)
        XCTAssertTrue(try store.delete(id: snippet.id))
        XCTAssertNil(try store.get(id: snippet.id))
        XCTAssertFalse(try store.delete(id: snippet.id))
    }

    func testFindMatching() throws {
        let store = try makeStore()
        _ = try store.create(Snippet(name: "Email reply", content: "Thanks, {clipboard}", keyword: "reply"))
        _ = try store.create(Snippet(name: "Date stamp", content: "{date}", keyword: "ds"))
        _ = try store.create(Snippet(name: "Misc", content: "Hello world", keyword: nil))

        let byName = try store.find(matching: "email")
        XCTAssertEqual(byName.map(\.name), ["Email reply"])

        let byKeyword = try store.find(matching: "ds")
        XCTAssertEqual(byKeyword.map(\.name), ["Date stamp"])

        let byContent = try store.find(matching: "world")
        XCTAssertEqual(byContent.map(\.name), ["Misc"])

        XCTAssertEqual(try store.find(matching: "   ").count, 3)
    }

    func testListOrderedByUpdatedAtDesc() throws {
        let store = try makeStore()
        let s1 = Snippet(
            name: "first",
            content: "1",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let s2 = Snippet(
            name: "second",
            content: "2",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try store.create(s1)
        _ = try store.create(s2)

        XCTAssertEqual(try store.list().map(\.name), ["second", "first"])
    }

    func testJSONRoundTrip() throws {
        let snippets = [
            Snippet(name: "A", content: "alpha {clipboard}", keyword: "a"),
            Snippet(name: "B", content: "{date:yyyy-MM-dd}", keyword: nil)
        ]
        let data = try SnippetJSONIO.encode(snippets)
        let decoded = try SnippetJSONIO.decode(data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "A")
        XCTAssertEqual(decoded[0].keyword, "a")
        XCTAssertEqual(decoded[1].content, "{date:yyyy-MM-dd}")
    }

    func testJSONImportDeduplicatesById() throws {
        let store = try makeStore()
        let id = UUID()
        let original = Snippet(id: id, name: "v1", content: "old")
        _ = try store.create(original)

        let incoming = [
            Snippet(id: id, name: "v2", content: "new"),
            Snippet(name: "fresh", content: "extra")
        ]
        let summary = try SnippetJSONIO.importSnippets(incoming, into: store)
        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(summary.total, 2)

        let reloaded = try store.get(id: id)
        XCTAssertEqual(reloaded?.name, "v2")
        XCTAssertEqual(reloaded?.content, "new")

        XCTAssertEqual(try store.list().count, 2)
    }
}
