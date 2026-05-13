import XCTest
@testable import PastaCore

final class SnippetPlaceholderEvaluatorTests: XCTestCase {
    private let frozenDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 13
        components.hour = 14
        components.minute = 7
        components.second = 9
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private func makeEvaluator(
        clipboardText: String? = nil,
        history: [String] = [],
        uuid: UUID = UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD")!
    ) -> SnippetPlaceholderEvaluator {
        SnippetPlaceholderEvaluator(
            now: { self.frozenDate },
            clipboardText: { clipboardText },
            history: { history },
            uuidProvider: { uuid },
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    func testPlainTextPassesThrough() {
        let result = makeEvaluator().evaluate("Hello, world!")
        XCTAssertEqual(result.text, "Hello, world!")
        XCTAssertNil(result.cursorOffset)
    }

    func testFormattedDate() {
        let result = makeEvaluator().evaluate("Today is {date:yyyy-MM-dd}.")
        XCTAssertEqual(result.text, "Today is 2026-05-13.")
    }

    func testFormattedTime() {
        let result = makeEvaluator().evaluate("At {time:HH:mm}.")
        XCTAssertEqual(result.text, "At 14:07.")
    }

    func testFormattedDatetimeCustomPattern() {
        let result = makeEvaluator().evaluate("{datetime:yyyy-MM-dd'T'HH:mm:ss}")
        XCTAssertEqual(result.text, "2026-05-13T14:07:09")
    }

    func testDefaultDateAndTimeUseLocaleFormatters() {
        // We don't assert exact strings (locale-dependent) — just that
        // tokens are replaced with non-empty content and that token is
        // gone.
        let result = makeEvaluator().evaluate("D: {date} | T: {time} | DT: {datetime}")
        XCTAssertFalse(result.text.contains("{date}"))
        XCTAssertFalse(result.text.contains("{time}"))
        XCTAssertFalse(result.text.contains("{datetime}"))
        XCTAssertTrue(result.text.hasPrefix("D: "))
    }

    func testClipboard() {
        let result = makeEvaluator(clipboardText: "FOO").evaluate("Hi {clipboard}!")
        XCTAssertEqual(result.text, "Hi FOO!")
    }

    func testClipboardEmptyWhenNil() {
        let result = makeEvaluator(clipboardText: nil).evaluate(">{clipboard}<")
        XCTAssertEqual(result.text, "><")
    }

    func testClipboardHistoryOneBased() {
        let result = makeEvaluator(history: ["latest", "earlier", "oldest"])
            .evaluate("1={clipboard:1} 2={clipboard:2} 3={clipboard:3}")
        XCTAssertEqual(result.text, "1=latest 2=earlier 3=oldest")
    }

    func testClipboardHistoryOutOfRange() {
        let result = makeEvaluator(history: ["a"]).evaluate("got=[{clipboard:5}]")
        XCTAssertEqual(result.text, "got=[]")
    }

    func testClipboardHistoryRejectsZeroAndNegative() {
        let result = makeEvaluator(history: ["a", "b"]).evaluate("z={clipboard:0} n={clipboard:-1}")
        XCTAssertEqual(result.text, "z= n=")
    }

    func testUUID() {
        let id = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let result = makeEvaluator(uuid: id).evaluate("id={uuid}")
        XCTAssertEqual(result.text, "id=DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")
    }

    func testCursorMarkerStrippedAndOffsetRecorded() {
        let result = makeEvaluator().evaluate("Hello {cursor}world")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.cursorOffset, 6)
    }

    func testOnlyFirstCursorOffsetIsRecorded() {
        let result = makeEvaluator().evaluate("a{cursor}b{cursor}c")
        XCTAssertEqual(result.text, "abc")
        XCTAssertEqual(result.cursorOffset, 1)
    }

    func testNoCursorMeansNilOffset() {
        let result = makeEvaluator().evaluate("plain")
        XCTAssertNil(result.cursorOffset)
    }

    func testUnknownPlaceholderLeftLiteral() {
        let result = makeEvaluator().evaluate("{foo} {bar:baz}")
        XCTAssertEqual(result.text, "{foo} {bar:baz}")
    }

    func testEmptyBracesLeftLiteral() {
        let result = makeEvaluator().evaluate("a{}b")
        XCTAssertEqual(result.text, "a{}b")
    }

    func testUnclosedBraceLeftLiteral() {
        let result = makeEvaluator().evaluate("a{date no close")
        XCTAssertEqual(result.text, "a{date no close")
    }

    func testNestedOpeningBraceLeftLiteral() {
        // Nested `{` inside a token bails — both braces are kept literal
        // and content is unchanged.
        let result = makeEvaluator().evaluate("a{ {date:y} }")
        XCTAssertTrue(result.text.contains("{"))
        // The inner `{date:y}` does still get evaluated because it is
        // a complete token starting at its own `{`.
        XCTAssertTrue(result.text.contains("2026"))
    }

    func testNewlineInTokenLeftLiteral() {
        let result = makeEvaluator().evaluate("{da\nte}")
        XCTAssertEqual(result.text, "{da\nte}")
    }

    func testCaseInsensitiveTokenName() {
        let result = makeEvaluator(clipboardText: "X").evaluate("{CLIPBOARD}/{Date:yyyy}")
        XCTAssertEqual(result.text, "X/2026")
    }

    func testMultiplePlaceholdersAndLiteralText() {
        let evaluator = makeEvaluator(
            clipboardText: "snippets",
            history: ["latest"]
        )
        let result = evaluator.evaluate(
            "Subject: {clipboard} on {date:yyyy-MM-dd}\nLast: {clipboard:1}{cursor}\nID: {uuid}"
        )
        XCTAssertEqual(
            result.text,
            "Subject: snippets on 2026-05-13\nLast: latest\nID: 00000000-0000-0000-0000-00000000ABCD"
        )
        XCTAssertNotNil(result.cursorOffset)
    }
}
