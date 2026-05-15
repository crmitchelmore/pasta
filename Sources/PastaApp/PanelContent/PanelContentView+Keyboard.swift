import AppKit
import SwiftUI

import PastaCore
import PastaUI

extension PanelContentView {
    func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // If the content-type picker is open, Esc closes it without changing
        // the filter (so it never falls through to closing the panel).
        if isShowingContentTypePicker, keyPress.key == .escape {
            isShowingContentTypePicker = false
            return .handled
        }

        switch keyPress.key {
        case .escape:
            closePanel()
            return .handled
        case .tab:
            if keyPress.modifiers.contains(.shift) {
                // Shift+Tab: reverse cycle.
                if listFocused {
                    listFocused = false
                    searchFocused = true
                } else {
                    searchFocused = false
                    listFocused = true
                }
            } else {
                if searchFocused {
                    searchFocused = false
                    listFocused = true
                } else {
                    listFocused = false
                    searchFocused = true
                }
            }
            return .handled

        case .upArrow:
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            moveSelection(delta: -1)
            return .handled

        case .downArrow:
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            moveSelection(delta: 1)
            return .handled

        case .return:
            if keyPress.modifiers.contains(.shift) || keyPress.modifiers.contains(.option) {
                pasteSelectedEntry(asPlainText: true)
            } else {
                pasteSelectedEntry()
            }
            return .handled

        case .delete:
            if keyPress.modifiers.contains(.command), let id = selectedEntryID,
               let entry = displayedEntries.first(where: { $0.id == id }) {
                deleteEntry(entry)
                return .handled
            }
            return .ignored

        default:
            break
        }

        // Quick paste (Cmd+1-9)
        let chars = keyPress.characters
        if keyPress.modifiers.contains(.command), chars.lowercased() == "f" {
            searchFocused = true
            return .handled
        }
        if keyPress.modifiers.contains(.command), chars.lowercased() == "p" {
            // Toggle the content-type filter picker (Raycast-style).
            // ⌘P would normally trigger Print, but Pasta is a panel app with
            // no Print menu so the shortcut is safe to repurpose.
            isShowingContentTypePicker.toggle()
            return .handled
        }
        if listFocused, keyPress.modifiers == .command, chars.lowercased() == "c" {
            copySelectedEntries()
            return .handled
        }
        if keyPress.modifiers.contains(.command), chars.lowercased() == "o" {
            if openSelectedEntryURL() { return .handled }
            return .ignored
        }
        if keyPress.modifiers.contains(.control), keyPress.modifiers.contains(.shift), chars.lowercased() == "x" {
            confirmClearAllHistory()
            return .handled
        }
        if keyPress.modifiers.contains(.command), keyPress.modifiers.contains(.shift), chars.lowercased() == "p" {
            togglePinSelectedEntry()
            return .handled
        }
        if keyPress.modifiers.contains(.command), chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
            quickPaste(index: digit - 1)
            return .handled
        }

        return .ignored
    }

    func moveSelection(delta: Int) {
        guard !displayedEntries.isEmpty else { return }

        let currentIndex: Int
        if let selectedEntryID, let idx = displayedEntries.firstIndex(where: { $0.id == selectedEntryID }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }

        let nextIndex = min(max(currentIndex + delta, 0), displayedEntries.count - 1)
        setSingleSelection(displayedEntries[nextIndex].id)
    }

    func quickPaste(index: Int) {
        guard index >= 0, index < displayedEntries.count else { return }
        setSingleSelection(displayedEntries[index].id)
        pasteSelectedEntry()
    }

    func setSingleSelection(_ id: UUID) {
        selectedEntryID = id
        lastSelectedEntryID = id
        selectedEntryIDs = [id]
    }

    func copySelectedEntries() {
        let selectedEntries = displayedEntries.filter { selectedEntryIDs.contains($0.id) }

        if selectedEntries.count > 1 {
            copyEntries(selectedEntries)
        } else if let entry = selectedEntries.first ??
            displayedEntries.first(where: { $0.id == selectedEntryID }) {
            copyEntry(entry)
        }
    }
}
