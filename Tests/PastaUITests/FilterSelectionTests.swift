import XCTest
import PastaCore
@testable import PastaUI

final class FilterSelectionTests: XCTestCase {
    func testSelectionsDeriveOnlyTheirOwnNarrowingFiltersAndSearchChromeLabels() {
        let cases: [(String, FilterSelection, ContentType?, String?, String?, Bool)] = [
            ("all", .all, nil, nil, nil, false),
            ("pinned", .pinned, nil, nil, nil, true),
            ("mixed", .mixed, nil, nil, nil, false),
            ("type", .type(.email), .email, nil, nil, false),
            ("domain", .domain("github.com"), .url, "github.com", nil, false),
            // "All Domains" narrows to URLs without a specific domain.
            ("all domains", .domain(""), .url, nil, nil, false),
            ("source app", .sourceApp("com.apple.Safari"), nil, nil, "com.apple.Safari", false)
        ]
        for (name, selection, contentType, domain, sourceApp, pinnedOnly) in cases {
            XCTAssertEqual(selection.contentType, contentType, "case \(name)")
            XCTAssertEqual(selection.urlDomain, domain, "case \(name)")
            XCTAssertEqual(selection.sourceApp, sourceApp, "case \(name)")
            XCTAssertEqual(selection.isPinnedOnly, pinnedOnly, "case \(name)")
        }

        // Result counts are capped at the page size with a "+" suffix.
        for (count, cap, label) in [(0, 200, "0"), (199, 200, "199"), (200, 200, "200+"), (500, 200, "200+"), (10, 10, "10+")] {
            XCTAssertEqual(SearchBarView.resultCountLabel(count, cap: cap), label)
        }
        XCTAssertEqual(SearchBarView.resultCountLabel(42), "42")
        XCTAssertEqual(SearchBarView.resultCountLabel(500), "200+")

        XCTAssertEqual(ShortcutHints.footerText(), "↩ Paste · ⇧↩ Plain text · ⌘⌫ Delete · ⌘P Filter · ⌘F Search")
        XCTAssertEqual(
            ShortcutHints.footerAccessibilityText([ShortcutHints.pastePlainText, ShortcutHints.delete]),
            "Shift Return: Plain text. Command Delete: Delete"
        )
    }
}
