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

    func testPlaceholdersExpandCursorIsRecordedAndMalformedTokensStayLiteral() {
        let id = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let cases: [(template: String, clipboard: String?, history: [String], uuid: UUID?,
                     text: String, cursor: Int?)] = [
            ("Hello, world!", nil, [], nil, "Hello, world!", nil),
            ("Today is {date:yyyy-MM-dd}.", nil, [], nil, "Today is 2026-05-13.", nil),
            ("At {time:HH:mm}.", nil, [], nil, "At 14:07.", nil),
            ("{datetime:yyyy-MM-dd'T'HH:mm:ss}", nil, [], nil, "2026-05-13T14:07:09", nil),
            ("Hi {clipboard}!", "FOO", [], nil, "Hi FOO!", nil),
            (">{clipboard}<", nil, [], nil, "><", nil),
            ("1={clipboard:1} 2={clipboard:2} 3={clipboard:3}", nil, ["latest", "earlier", "oldest"], nil,
             "1=latest 2=earlier 3=oldest", nil),
            ("got=[{clipboard:5}]", nil, ["a"], nil, "got=[]", nil),
            ("z={clipboard:0} n={clipboard:-1}", nil, ["a", "b"], nil, "z= n=", nil),
            ("id={uuid}", nil, [], id, "id=DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF", nil),
            ("Hello {cursor}world", nil, [], nil, "Hello world", 6),
            ("a{cursor}b{cursor}c", nil, [], nil, "abc", 1),
            ("{foo} {bar:baz}", nil, [], nil, "{foo} {bar:baz}", nil),
            ("a{}b", nil, [], nil, "a{}b", nil),
            ("a{date no close", nil, [], nil, "a{date no close", nil),
            ("{da\nte}", nil, [], nil, "{da\nte}", nil),
            ("{CLIPBOARD}/{Date:yyyy}", "X", [], nil, "X/2026", nil),
            ("Subject: {clipboard} on {date:yyyy-MM-dd}\nLast: {clipboard:1}{cursor}\nID: {uuid}", "snippets", ["latest"], nil,
             "Subject: snippets on 2026-05-13\nLast: latest\nID: 00000000-0000-0000-0000-00000000ABCD", 44)
        ]
        for testCase in cases {
            let evaluator = testCase.uuid.map {
                makeEvaluator(clipboardText: testCase.clipboard, history: testCase.history, uuid: $0)
            } ?? makeEvaluator(clipboardText: testCase.clipboard, history: testCase.history)
            let result = evaluator.evaluate(testCase.template)
            XCTAssertEqual(result.text, testCase.text, testCase.template)
            XCTAssertEqual(result.cursorOffset, testCase.cursor, testCase.template)
        }

        // Locale-dependent defaults: only assert the tokens were replaced.
        let defaults = makeEvaluator().evaluate("D: {date} | T: {time} | DT: {datetime}").text
        for token in ["{date}", "{time}", "{datetime}"] {
            XCTAssertFalse(defaults.contains(token), token)
        }
        XCTAssertTrue(defaults.hasPrefix("D: "))

        // A nested `{` keeps the outer braces literal; the inner complete token still expands.
        let nested = makeEvaluator().evaluate("a{ {date:y} }").text
        XCTAssertTrue(nested.contains("{"))
        XCTAssertTrue(nested.contains("2026"))
    }
}
