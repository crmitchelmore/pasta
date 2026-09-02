import XCTest
@testable import PastaUI

final class ShortcutHintsTests: XCTestCase {
    func testFooterTextJoinsHintsWithMiddleDots() {
        XCTAssertEqual(
            ShortcutHints.footerText(),
            "↩ Paste · ⇧↩ Plain text · ⌘⌫ Delete · ⌘P Filter · ⌘F Search"
        )
    }

    func testFooterAccessibilityTextSpellsOutModifierGlyphs() {
        let text = ShortcutHints.footerAccessibilityText([
            ShortcutHints.pastePlainText,
            ShortcutHints.delete
        ])
        XCTAssertEqual(text, "Shift Return: Plain text. Command Delete: Delete")
    }
}
