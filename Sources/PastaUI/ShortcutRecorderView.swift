import AppKit
import KeyboardShortcuts
import SwiftUI

/// A custom shortcut recorder that avoids KeyboardShortcuts.Recorder's
/// dependency on Bundle.module (which crashes in manually-assembled app bundles).
struct ShortcutRecorderView: View {
    let name: KeyboardShortcuts.Name
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if isRecording {
                Text("Press shortcut…")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 120)
            } else if let shortcut = currentShortcut {
                Text(shortcut.description)
                    .frame(minWidth: 120)
            } else {
                Text("None")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 120)
            }

            if isRecording {
                Button {
                    stopRecording()
                } label: {
                    Image(systemName: "escape")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Cancel recording")
            } else {
                if currentShortcut != nil, currentShortcut != name.defaultShortcut {
                    Button {
                        KeyboardShortcuts.reset(name)
                        currentShortcut = KeyboardShortcuts.getShortcut(for: name)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default")
                }
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
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: name)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // Temporarily disable the shortcut while recording
        KeyboardShortcuts.disable(name)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // Require at least one modifier key (Cmd, Ctrl, Option, or Shift)
            guard !modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                return nil
            }

            guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
                return nil
            }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            currentShortcut = shortcut
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
            KeyboardShortcuts.enable(name)
        }
    }
}
