import AppKit
import Carbon
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
                Text(shortcut.displayString)
                    .font(.system(.body, design: .rounded))
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
        KeyboardShortcuts.disable(name)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // Require at least one modifier key
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

// MARK: - Safe display string (avoids Bundle.module / .localized)

extension KeyboardShortcuts.Shortcut {
    /// Display string built without triggering Bundle.module lookups.
    var displayString: String {
        var parts: [String] = []
        let mods = modifiers
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        parts.append(keyString(for: carbonKeyCode))
        return parts.joined()
    }

    private func keyString(for keyCode: Int) -> String {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 71: return "⎋"
        case 76: return "⌤"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            // Use the key character from the current keyboard layout
            let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            if let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length: Int = 0
                data.withUnsafeBytes { ptr in
                    let layoutPtr = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
                    UCKeyTranslate(
                        layoutPtr,
                        UInt16(keyCode),
                        UInt16(kUCKeyActionDisplay),
                        0,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &length,
                        &chars
                    )
                }
                if length > 0 {
                    return String(utf16CodeUnits: chars, count: length).uppercased()
                }
            }
            return "Key\(keyCode)"
        }
    }
}
