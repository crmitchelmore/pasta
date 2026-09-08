import XCTest
@testable import PastaCore

final class SnippetKeywordMatcherTests: XCTestCase {
    func testOnlyExactUniqueKeywordsExpandAtBoundary() {
        let snippet = Snippet(name: "Greeting", content: "Hello", keyword: ";hi")
        var matcher = SnippetKeywordMatcher()
        for ch in ";hi" { XCTAssertNil(matcher.consume(String(ch), snippets: [snippet])) }
        let match = matcher.consume(" ", snippets: [snippet])
        XCTAssertEqual(match?.id, snippet.id)
        XCTAssertEqual(match?.deleteCount, 4)
        XCTAssertEqual(matcher.token, "")
        _ = matcher.consume(";hi", snippets: [snippet])
        XCTAssertNil(matcher.consume(" ", snippets: [snippet, Snippet(name: "Duplicate", content: "x", keyword: ";hi")]))
    }

    func testResetBackspaceAndBoundedInputDoNotExpandStaleWords() {
        let snippet = Snippet(name: "Greeting", content: "Hello", keyword: ";hi")
        var matcher = SnippetKeywordMatcher()
        _ = matcher.consume(";hix", snippets: [snippet])
        _ = matcher.consume("\u{7f}", snippets: [snippet])
        XCTAssertEqual(matcher.token, ";hi")
        matcher.reset()
        XCTAssertNil(matcher.consume(" ", snippets: [snippet]))
        _ = matcher.consume(String(repeating: "a", count: 129), snippets: [snippet])
        XCTAssertEqual(matcher.token, "")
        _ = matcher.consume(";hi", snippets: [snippet])
        _ = matcher.consume("\u{1b}", snippets: [snippet])
        XCTAssertNil(matcher.consume(" ", snippets: [snippet]))
    }
}
