import AppKit
import SwiftUI

import PastaUI

/// Presents first-launch onboarding in a window of its own rather than as a
/// sheet on the panel.
///
/// AppKit refuses `NSApplication.terminate(_:)` while any window has a sheet
/// attached ("App termination blocked by modal sheet"), and it never asks the
/// app delegate. With onboarding as a sheet, ⌘Q, the status-item Quit and
/// SIGTERM-driven quits silently did nothing until the user finished or
/// dismissed it (pasta-adt). A plain floating window has no such side effect,
/// and the CI launch smoke test — which quits with onboarding on screen on
/// every fresh runner — is the regression test for that.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var onFinish: ((OnboardingView.Completion) -> Void)?
    private var finished = false

    /// Shows onboarding (or brings the existing window forward). `onFinish`
    /// runs exactly once, with `.dismissed` if the window is simply closed.
    func present(onFinish: @escaping (OnboardingView.Completion) -> Void) {
        self.onFinish = onFinish
        finished = false

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Pasta"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // Above the floating panel that triggered it, on whichever Space.
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView { [weak self] completion in
                self?.finish(with: completion)
            })
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish(with completion: OnboardingView.Completion) {
        guard !finished else { return }
        finished = true
        let callback = onFinish
        onFinish = nil
        window?.orderOut(nil)
        window = nil
        callback?(completion)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The user hit the close button: same as choosing to skip.
        finish(with: .dismissed)
    }
}
