import Foundation
import XCTest
@testable import PastaCore

final class SnippetRendererTests: XCTestCase {
    func testPasteReadsLatestSavedTemplateAndHistoryAtActivation() throws {
        let database = try DatabaseManager.inMemory()
        let store = SnippetStore(database: database)
        var snippet = Snippet(name: "Reply", content: "old", keyword: "reply")
        try store.create(snippet)
        let commands = SnippetCommands.commands(for: try store.find(matching: "REPLY"))
        XCTAssertEqual(commands.count, 1)
        snippet.content = "{clipboard:2}|{clipboard:1}|{clipboard}|{cursor}👨‍👩‍👧‍👦é"
        try store.update(snippet)
        try database.insert(ClipboardEntry(content: "older", contentType: .text, timestamp: Date(timeIntervalSince1970: 1)))
        try database.insert(ClipboardEntry(content: "latest", contentType: .text, timestamp: Date(timeIntervalSince1970: 2)))
        let rendered = try XCTUnwrap(SnippetRenderer(database: database).render(id: snippet.id, clipboardText: "current"))
        XCTAssertEqual(rendered.text, "older|latest|current|👨‍👩‍👧‍👦é")
        XCTAssertEqual(rendered.cursorMoveCount, 2)
        try store.delete(id: snippet.id)
        XCTAssertNil(try SnippetRenderer(database: database).render(id: snippet.id, clipboardText: nil))
    }

    func testExplicitPickerQueryAndLiteralKeywordSearch() throws {
        XCTAssertEqual(SnippetCommands.searchQuery("SNIPPET greeting"), "greeting")
        XCTAssertEqual(SnippetCommands.searchQuery("snippets"), "")
        XCTAssertNil(SnippetCommands.searchQuery("snippetish"))
        let database = try DatabaseManager.inMemory()
        let store = SnippetStore(database: database)
        try store.create(Snippet(name: "Percent", content: "literal", keyword: "%_"))
        try store.create(Snippet(name: "Other", content: "normal"))
        XCTAssertEqual(try store.find(matching: "%_").map(\.name), ["Percent"])
    }
}
