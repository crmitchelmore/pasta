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
            guard let self else { return }
            Task { @MainActor in
                self.isVisible = false
            }
        }
    }
}

// MARK: - Quick Search Window (Spotlight-like)

/// A borderless floating window for quick search, similar to Spotlight/Alfred
final class QuickSearchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Floating behavior
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        
        // Visual styling
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // SwiftUI view provides shadow
        
        // Allow key events
        isMovableByWindowBackground = true
        
        // Don't release on close
        isReleasedWhenClosed = false
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Controller for the quick search panel
@MainActor
final class QuickSearchController: ObservableObject {
    private var window: QuickSearchWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var resignObserver: NSObjectProtocol?
    
    @Published private(set) var isVisible: Bool = false
    
    private var contentBuilder: (() -> AnyView)?
    
    func setContent<V: View>(_ content: @escaping () -> V) {
        self.contentBuilder = { AnyView(content()) }
    }
    
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
    
    func show() {
        guard let contentBuilder else { return }
        
        if window == nil {
            createWindow()
        }
        
        // Update content
        hostingView?.rootView = contentBuilder()
        
        guard let window else { return }
        
        // Position near top center of screen (Spotlight-style)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            // Size will be determined by content, but set initial frame
            let width: CGFloat = 680
            let height: CGFloat = 400
            let x = screenFrame.midX - width / 2
            let y = screenFrame.maxY - height - 150  // Near top
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
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
        guard let contentBuilder else { return }
        
        let contentRect = NSRect(x: 0, y: 0, width: 680, height: 400)
        window = QuickSearchWindow(contentRect: contentRect)
        
        let hosting = NSHostingView(rootView: contentBuilder())
        hosting.frame = contentRect
        window?.contentView = hosting
        hostingView = hosting
        
        // Hide on deactivation
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.hide()
            }
        }
    }
    
    deinit {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
