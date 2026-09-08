import AppKit
import PastaCore

/// Send the paste only after the selected receiving app has regained focus.
/// Posting Cmd+V while the panel is still key pastes into Pasta's own controls.
@MainActor
final class ExternalPasteCoordinator {
    static let shared = ExternalPasteCoordinator()
    private var previousApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.remember(application) }
        }
    }

    private func remember(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular else { return }
        previousApplication = application
    }

    func paste(_ entry: ClipboardEntry, asPlainText: Bool = false, cursorMoveCount: Int = 0, hide: () -> Void) {
        let target = previousApplication
        let copied = asPlainText
            ? (!entry.content.isEmpty && PasteService().copy(ClipboardEntry(content: entry.content, contentType: .text)))
            : PasteService().copy(entry)
        guard copied else { return }
        hide()
        NSApp.hide(nil)
        guard let target, !target.isTerminated, AccessibilityPermission.isTrusted() else { return }
        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
            SystemPasteEventSimulator().simulateCommandV()
            if cursorMoveCount > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return }
                    SystemPasteEventSimulator().moveCursorLeft(by: cursorMoveCount)
                }
            }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
