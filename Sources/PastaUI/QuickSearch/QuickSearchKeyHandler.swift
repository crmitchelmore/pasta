import AppKit
import SwiftUI

// MARK: - Key Handler (NSViewRepresentable to capture keys globally)

struct QuickSearchKeyHandler<Content: View>: NSViewRepresentable {
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onArrowRight: () -> Void
    let onArrowLeft: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void
    let onCommandNumber: (Int) -> Void
    let content: Content

    init(
        onArrowUp: @escaping () -> Void,
        onArrowDown: @escaping () -> Void,
        onArrowRight: @escaping () -> Void,
        onArrowLeft: @escaping () -> Void,
        onReturn: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onCommandNumber: @escaping (Int) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onArrowUp = onArrowUp
        self.onArrowDown = onArrowDown
        self.onArrowRight = onArrowRight
        self.onArrowLeft = onArrowLeft
        self.onReturn = onReturn
        self.onEscape = onEscape
        self.onCommandNumber = onCommandNumber
        self.content = content()
    }

    func makeNSView(context: Context) -> KeyInterceptingView {
        KeyInterceptingView(
            onArrowUp: onArrowUp,
            onArrowDown: onArrowDown,
            onArrowRight: onArrowRight,
            onArrowLeft: onArrowLeft,
            onReturn: onReturn,
            onEscape: onEscape,
            onCommandNumber: onCommandNumber,
            content: content
        )
    }

    func updateNSView(_ nsView: KeyInterceptingView, context: Context) {
        nsView.onArrowUp = onArrowUp
        nsView.onArrowDown = onArrowDown
        nsView.onArrowRight = onArrowRight
        nsView.onArrowLeft = onArrowLeft
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
        nsView.onCommandNumber = onCommandNumber
        nsView.updateContent(content)
    }
}

final class KeyInterceptingView: NSView {
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onArrowRight: () -> Void
    var onArrowLeft: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void
    var onCommandNumber: (Int) -> Void

    private var hostingView: NSHostingController<AnyView>?
    private var localMonitor: Any?

    init<Content: View>(
        onArrowUp: @escaping () -> Void,
        onArrowDown: @escaping () -> Void,
        onArrowRight: @escaping () -> Void,
        onArrowLeft: @escaping () -> Void,
        onReturn: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onCommandNumber: @escaping (Int) -> Void,
        content: Content
    ) {
        self.onArrowUp = onArrowUp
        self.onArrowDown = onArrowDown
        self.onArrowRight = onArrowRight
        self.onArrowLeft = onArrowLeft
        self.onReturn = onReturn
        self.onEscape = onEscape
        self.onCommandNumber = onCommandNumber
        super.init(frame: .zero)

        let hosting = NSHostingController(rootView: AnyView(content))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        hostingView = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateContent<Content: View>(_ content: Content) {
        hostingView?.rootView = AnyView(content)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Install monitor when we have a window, remove when we don't
        if window != nil && localMonitor == nil {
            // Use local monitor to intercept keys before TextField consumes them
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                return self.handleKeyEvent(event) ? nil : event
            }
        } else if window == nil, let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Handle Cmd+1-9 (check if command is the only modifier)
        if modifiers.contains(.command) && !modifiers.contains(.shift) && !modifiers.contains(.option) && !modifiers.contains(.control) {
            if let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars),
               digit >= 1 && digit <= 9 {
                onCommandNumber(digit)
                return true
            }
        }

        // Handle arrow keys and other keys (only when no modifiers except function/numericPad)
        let baseModifiers = modifiers.subtracting([.function, .numericPad])

        switch event.keyCode {
        case 126: // Up arrow
            if baseModifiers.isEmpty {
                onArrowUp()
                return true
            }
        case 125: // Down arrow
            if baseModifiers.isEmpty {
                onArrowDown()
                return true
            }
        case 124: // Right arrow
            if baseModifiers.isEmpty {
                onArrowRight()
                return true
            }
        case 123: // Left arrow
            if baseModifiers.isEmpty {
                onArrowLeft()
                return true
            }
        case 36: // Return
            if baseModifiers.isEmpty {
                onReturn()
                return true
            }
        case 53: // Escape
            onEscape()
            return true
        default:
            break
        }

        return false
    }
}
