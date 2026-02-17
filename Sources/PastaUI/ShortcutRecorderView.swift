#if os(macOS)
import AppKit
import SwiftUI

/// A SwiftUI view that lets the user record a keyboard shortcut.
/// Uses NSEvent local monitoring — no third-party dependencies or Bundle.module.
struct ShortcutRecorderView: View {
    @State private var currentHotKey: PastaHotKey
    @State private var isRecording = false
    @State private var pendingModifiers: PastaHotKey.ModifierSet = []
    @State private var eventMonitor: Any?

    init(hotKey: PastaHotKey) {
        self._currentHotKey = State(initialValue: hotKey)
    }

    var body: some View {
        HStack(spacing: 6) {
            if isRecording {
                recordingLabel
            } else {
                Text(currentHotKey.displayString)
                    .font(.system(.body, design: .rounded))
                    .frame(minWidth: 120)
            }

            if !isRecording, currentHotKey != .defaultHotKey {
                Button {
                    currentHotKey = .defaultHotKey
                    currentHotKey.save()
                    NotificationCenter.default.post(name: .pastaHotKeyDidChange, object: nil)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isRecording ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onTapGesture {
            if !isRecording {
                startRecording()
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var recordingLabel: some View {
        HStack(spacing: 4) {
            if !pendingModifiers.isEmpty {
                Text(pendingModifiers.displayString)
                    .font(.system(.body, design: .rounded))
            }
            Text("Press shortcut…")
                .foregroundStyle(.secondary)
                .frame(minWidth: 100)
        }
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        pendingModifiers = []

        // Pause the global hotkey so the key event reaches our monitor
        NotificationCenter.default.post(name: .pastaHotKeyShouldPause, object: nil)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Track modifier-only presses
            if KeyCodeMapping.modifierKeyCodes.contains(event.keyCode) {
                pendingModifiers = PastaHotKey.ModifierSet(from: event.modifierFlags)
                return nil
            }

            // Escape cancels recording
            if event.keyCode == 53 && pendingModifiers.isEmpty {
                stopRecording()
                return nil
            }

            let modifiers = PastaHotKey.ModifierSet(
                from: event.modifierFlags.intersection([.command, .shift, .option, .control])
            )

            // Require at least one modifier
            guard !modifiers.isEmpty else { return nil }

            let hotKey = PastaHotKey(keyCode: event.keyCode, modifiers: modifiers)
            currentHotKey = hotKey
            hotKey.save()
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if isRecording {
            isRecording = false
            pendingModifiers = []
        }
        // Re-register the hotkey (possibly with new key)
        NotificationCenter.default.post(name: .pastaHotKeyDidChange, object: nil)
    }
}

// MARK: - Hotkey lifecycle notifications

public extension Notification.Name {
    /// Posted when the hotkey should be temporarily unregistered (e.g. during recording).
    static let pastaHotKeyShouldPause = Notification.Name("pasta.hotKeyShouldPause")
    /// Posted when the hotkey configuration changed and should be re-registered.
    static let pastaHotKeyDidChange = Notification.Name("pasta.hotKeyDidChange")
}

#endif
