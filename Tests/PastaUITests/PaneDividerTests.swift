#if os(macOS)
import AppKit
import XCTest
@testable import PastaUI

final class PaneDividerTests: XCTestCase {
    @MainActor
    func testDragUsesWindowCoordinatesWhileDividerMovesAndReverses() throws {
        let (window, divider) = makeDivider()
        defer { window.close() }
        let windowFrame = window.frame
        var translations: [CGFloat] = []
        var ends = 0
        divider.onDragChanged = { delta in
            translations.append(delta)
            // Reproduce the layout feedback that broke the SwiftUI local gesture.
            divider.setFrameOrigin(NSPoint(x: 200 + delta, y: 0))
        }
        divider.onDragEnded = { ends += 1 }

        divider.mouseDown(with: try event(.leftMouseDown, x: 204, window: window))
        for x: CGFloat in [224, 264, 244, 184, 164] {
            divider.mouseDragged(with: try event(.leftMouseDragged, x: x, window: window))
        }
        divider.mouseUp(with: try event(.leftMouseUp, x: 154, window: window))

        XCTAssertEqual(translations, [0, 20, 60, 40, -20, -40, -50])
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(divider.frame.minX, 150)
        XCTAssertEqual(window.frame, windowFrame)
        XCTAssertFalse(divider.mouseDownCanMoveWindow)
        XCTAssertTrue(divider.acceptsFirstMouse(for: nil))
        XCTAssertTrue(window.contentView?.hitTest(NSPoint(x: 154, y: 80)) === divider)
    }

    @MainActor
    func testDragContinuesOutsideHitAreaAndNewDragGetsFreshOrigin() throws {
        let (window, divider) = makeDivider()
        defer { window.close() }
        var translations: [CGFloat] = []
        var ends = 0
        divider.onDragChanged = { translations.append($0) }
        divider.onDragEnded = { ends += 1 }

        divider.mouseDown(with: try event(.leftMouseDown, x: 204, window: window))
        // A pane can reach its minimum width while the pointer keeps moving.
        divider.mouseDragged(with: try event(.leftMouseDragged, x: 900, window: window))
        divider.mouseUp(with: try event(.leftMouseUp, x: 950, window: window))
        divider.mouseDragged(with: try event(.leftMouseDragged, x: 960, window: window))
        divider.mouseDown(with: try event(.leftMouseDown, x: 202, window: window))
        divider.mouseDragged(with: try event(.leftMouseDragged, x: 182, window: window))
        divider.mouseUp(with: try event(.leftMouseUp, x: 182, window: window))

        XCTAssertEqual(translations, [0, 696, 746, 0, -20, -20])
        XCTAssertEqual(ends, 2)
    }

    @MainActor
    func testCursorSurvivesLayoutUpdatesAndExitDuringDrag() throws {
        let (window, divider) = makeDivider()
        defer { window.close(); NSCursor.arrow.set() }
        divider.mouseDown(with: try event(.leftMouseDown, x: 204, window: window))
        for _ in 0..<3 {
            divider.updateTrackingAreas()
            divider.resetCursorRects()
            divider.cursorUpdate(with: try event(.cursorUpdate, x: 204, window: window))
            XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        }
        XCTAssertEqual(divider.trackingAreas.count, 1)
        divider.mouseExited(with: try event(.mouseExited, x: 220, window: window))
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        divider.mouseUp(with: try event(.leftMouseUp, x: 220, window: window))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    @MainActor
    private func makeDivider() -> (NSWindow, PaneDividerView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        let divider = PaneDividerView(frame: NSRect(x: 200, y: 0, width: 8, height: 300))
        window.contentView?.addSubview(divider)
        return (window, divider)
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, x: CGFloat, window: NSWindow) throws -> NSEvent {
        if type == .cursorUpdate || type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(
                with: type, location: NSPoint(x: x, y: 80), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil
            ))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 80), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }
}
#endif
