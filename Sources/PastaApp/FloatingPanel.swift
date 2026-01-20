import AppKit
import SwiftUI

/// A standard resizable window that appears in app switcher.
final class MainWindow<Content: View>: NSWindow {
    init(contentRect: NSRect, content: @escaping () -> Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // Standard window behavior
        titlebarAppearsTransparent = false
        titleVisibility = .visible
        title = "Pasta"
        isMovableByWindowBackground = true
        
        // Don't hide when app deactivates
        isReleasedWhenClosed = false
        
        // Visual styling
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        
        // Minimum size
        minSize = NSSize(width: 600, height: 400)
        
        // Host SwiftUI content
        let hostingView = NSHostingView(rootView: content())
        contentView = hostingView
    }
    
    // Allow the window to become key and main
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    // Close on Escape key
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Controller that manages the main window lifecycle.
@MainActor
final class PanelController<Content: View>: ObservableObject {
    private var window: MainWindow<Content>?
    private let contentBuilder: () -> Content
    private let windowSize: NSSize
    
    @Published private(set) var isVisible: Bool = false
    
    init(size: NSSize, content: @escaping () -> Content) {
        self.windowSize = size
        self.contentBuilder = content
    }
    
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
    
    func show() {
        if window == nil {
            createWindow()
        }
        
        guard let window else { return }
        
        // Center on screen if not already visible
        if !isVisible, let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - window.frame.width / 2
            let y = screenFrame.midY - window.frame.height / 2 + 50
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }
    
    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
    
    private func createWindow() {
        let contentRect = NSRect(origin: .zero, size: windowSize)
        window = MainWindow(contentRect: contentRect, content: contentBuilder)
        
        // Observe window close to update state
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isVisible = false
            }
        }
    }
}
