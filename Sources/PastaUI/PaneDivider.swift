#if os(macOS)
import AppKit
import SwiftUI

/// A pane divider that owns its mouse sequence even in a background-draggable window.
public struct PaneDivider: View {
    private let label: String
    private let width: CGFloat
    private let onDragChanged: (CGFloat) -> Void
    private let onDragEnded: () -> Void

    public init(
        label: String,
        width: CGFloat = 8,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.label = label
        self.width = width
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    public var body: some View {
        NativePaneDivider(label: label, onDragChanged: onDragChanged, onDragEnded: onDragEnded)
            .frame(width: width)
    }
}

private struct NativePaneDivider: NSViewRepresentable {
    let label: String
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> PaneDividerView {
        let view = PaneDividerView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PaneDividerView, context: Context) {
        view.toolTip = label
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(label)
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

final class PaneDividerView: NSView {
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    private var dragStartX: CGFloat?
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    // Otherwise the containing NSWindow can turn a divider drag into a window drag.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        if dragStartX == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        // The view's own origin moves during layout. Window coordinates do not,
        // so cumulative motion cannot feed back into the next drag translation.
        dragStartX = event.locationInWindow.x
        NSCursor.resizeLeftRight.set()
        needsDisplay = true
        onDragChanged(0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        NSCursor.resizeLeftRight.set()
        onDragChanged(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartX else { return }
        onDragChanged(event.locationInWindow.x - dragStartX)
        self.dragStartX = nil
        onDragEnded()
        isHovering = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        (isHovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHovering || dragStartX != nil
        let lineWidth: CGFloat = highlighted ? 3 : 1
        let color = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        color.setFill()
        let line = NSRect(x: bounds.midX - lineWidth / 2, y: bounds.minY,
                          width: lineWidth, height: bounds.height)
        NSBezierPath(roundedRect: line, xRadius: lineWidth / 2, yRadius: lineWidth / 2).fill()
    }
}
#endif
