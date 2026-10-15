import AppKit
import XCTest
@testable import PastaUI

@MainActor
final class QuickSearchKeyHandlerTests: XCTestCase {
    func testCommandDeleteIsLeftToTextFieldWhenSearchHasText() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        XCTAssertFalse(KeyInterceptingView.focusedTextHasContent(in: window))
        textView.string = "hello world"
        XCTAssertTrue(KeyInterceptingView.focusedTextHasContent(in: window))
        XCTAssertFalse(KeyInterceptingView.focusedTextHasContent(in: nil))
    }
}
