import AppKit
import Carbon
import PastaCore

/// Opt-in keyword expansion. Secure input, focus changes, pointer activity and
/// command shortcuts reset the bounded token. Nothing is logged or transmitted.
@MainActor
final class SnippetExpansionController {
    static let enabledKey = "pasta.snippetKeywordExpansionEnabled"
    private var monitor: Any?
    private var snippets: [Snippet] = []
    private var matcher = SnippetKeywordMatcher()
    private var targetPID: pid_t?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [UserDefaults.didChangeNotification, .snippetsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        generation += 1
        matcher.reset()
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
            && AccessibilityPermission.isTrusted() && AccessibilityPermission.hasInputMonitoring() && ProcessInfo.processInfo.environment["PASTA_CI"] == nil
        guard enabled else {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            snippets = []
            return
        }
        do { snippets = try SnippetStore(database: BackgroundService.shared.database).list() }
        catch { snippets = []; PastaLogger.logError(error, logger: PastaLogger.app, context: "Could not load snippet keywords") }
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == SystemPasteEventSimulator.syntheticEventMarker { return }
        generation += 1
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid != targetPID { matcher.reset(); targetPID = pid }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), AccessibilityPermission.isTrusted(),
              !IsSecureEventInputEnabled(), event.type == .keyDown,
              ![123, 124, 125, 126, 115, 119, 116, 121, 53].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters else { matcher.reset(); return }
        guard let match = matcher.consume(characters, snippets: snippets), let pid else { return }
        let version = generation
        let database = BackgroundService.shared.database
        let clipboard = NSPasteboard.general.string(forType: .string)
        Task {
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try SnippetRenderer(database: database).render(id: match.id, clipboardText: clipboard)
                }.value
                // If the user kept typing, switched apps or disabled expansion,
                // leave their text alone. Never erase text based on stale input.
                guard let rendered, version == generation, !IsSecureEventInputEnabled(),
                      UserDefaults.standard.bool(forKey: Self.enabledKey),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let source = CGEventSource(stateID: .combinedSessionState) else { return }
                _ = PasteService().copy(ClipboardEntry(content: rendered.text, contentType: .text))
                for _ in 0..<match.deleteCount {
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)
                        event?.setIntegerValueField(.eventSourceUserData, value: SystemPasteEventSimulator.syntheticEventMarker)
                        event?.post(tap: .cghidEventTap)
                    }
                }
                SystemPasteEventSimulator().simulateCommandV()
                if rendered.cursorMoveCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard self.generation == version, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                              !IsSecureEventInputEnabled() else { return }
                        SystemPasteEventSimulator().moveCursorLeft(by: rendered.cursorMoveCount)
                    }
                }
            } catch { PastaLogger.logError(error, logger: PastaLogger.app, context: "Keyword expansion failed") }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
