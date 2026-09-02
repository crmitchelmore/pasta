import AppKit
import PastaCore
import SwiftUI

public struct SearchBarView: View {
    @Binding private var query: String
    @Binding private var contentType: ContentType?
    @Binding private var sourceAppFilter: String
    @Binding private var showContentTypePicker: Bool

    private let resultCount: Int
    private let availableContentTypes: [ContentType]
    private let onOpenSettings: () -> Void
    private let searchFocused: FocusState<Bool>.Binding

    @State private var isFieldFocused: Bool = false

    public init(
        query: Binding<String>,
        contentType: Binding<ContentType?>,
        resultCount: Int,
        sourceAppFilter: Binding<String>,
        availableContentTypes: [ContentType] = [],
        showContentTypePicker: Binding<Bool> = .constant(false),
        onOpenSettings: @escaping () -> Void,
        searchFocused: FocusState<Bool>.Binding
    ) {
        _query = query
        _contentType = contentType
        self.resultCount = resultCount
        _sourceAppFilter = sourceAppFilter
        self.availableContentTypes = availableContentTypes
        _showContentTypePicker = showContentTypePicker
        self.onOpenSettings = onOpenSettings
        self.searchFocused = searchFocused
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Main search bar - the hero element
            HStack(spacing: 0) {
                // Search icon with subtle pulse when focused
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isFieldFocused ? Color.accentColor : .secondary)
                    .scaleEffect(isFieldFocused ? 1.1 : 1.0)
                    .frame(width: 44)
                
                // Search input
                SearchField(
                    text: $query,
                    placeholder: "Search your clipboard history...",
                    isFocused: searchFocused,
                    onFocusChange: { focused in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isFieldFocused = focused
                        }
                    }
                )
                
                // Clear button (when has text)
                if !query.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            query = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                    .transition(.scale.combined(with: .opacity))
                }

                // Active content-type filter chip (also visible to confirm
                // selections made via the ⌘P picker or sidebar).
                if let activeType = contentType {
                    ContentTypeFilterChip.activeDismissable(type: activeType, onClear: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            contentType = nil
                        }
                    })
                    .padding(.trailing, 8)
                    .transition(.scale.combined(with: .opacity))
                }

                // Result count badge
                Text("\(resultCount)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )
                    .padding(.trailing, 12)
                    .contentTransition(.numericText(value: Double(resultCount)))
                    .popover(isPresented: $showContentTypePicker, arrowEdge: .bottom) {
                        ContentTypePickerView(
                            availableTypes: availableContentTypes,
                            selectedType: contentType,
                            onSelect: { newType in
                                contentType = newType
                                showContentTypePicker = false
                            },
                            onCancel: {
                                showContentTypePicker = false
                            }
                        )
                    }
            }
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background {
                // Layered background for depth
                ZStack {
                    // Base fill
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    
                    // Accent glow overlay when focused
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(isFieldFocused ? 0.08 : 0))
                    
                    // Border with gradient
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isFieldFocused
                                ? Color.accentColor.opacity(0.8)
                                : Color.primary.opacity(0.1),
                            lineWidth: isFieldFocused ? 2 : 1
                        )
                }
            }
            // Outer glow - accent colored, expands on focus
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor)
                    .blur(radius: isFieldFocused ? 16 : 8)
                    .opacity(isFieldFocused ? 0.4 : 0.0)
                    .scaleEffect(isFieldFocused ? 1.04 : 0.96)
            }
            // Soft drop shadow
            .shadow(color: Color.accentColor.opacity(isFieldFocused ? 0.3 : 0), radius: 8, y: 2)
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isFieldFocused)
            
            // Settings button - separate from search bar, larger hit target
            SettingsButton(onTap: onOpenSettings)
                .frame(width: 48, height: 48)
        }
        .padding(.horizontal, 4)
    }
}

// Separate view for settings button using NSViewRepresentable for reliable click handling
private struct SettingsButton: NSViewRepresentable {
    let onTap: () -> Void
    
    func makeNSView(context: Context) -> HoverButton {
        let button = HoverButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        // Use a semi-transparent color that works in both light and dark mode
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        
        // Create a larger image
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked)
        button.toolTip = "Settings (⌘,)"
        
        return button
    }
    
    func updateNSView(_ nsView: HoverButton, context: Context) {
        nsView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }
    
    class Coordinator: NSObject {
        let onTap: () -> Void
        
        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }
        
        @objc func buttonClicked() {
            onTap()
        }
    }
    
    /// NSButton subclass that owns its own tracking area for hover effects,
    /// avoiding crashes from dangling Coordinator references during NSAlert modal loops.
    final class HoverButton: NSButton {
        private var hoverTrackingArea: NSTrackingArea?
        
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = hoverTrackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }
        
        override func mouseEntered(with event: NSEvent) {
            contentTintColor = .labelColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        }
        
        override func mouseExited(with event: NSEvent) {
            contentTintColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

// MARK: - Search Field

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isFocused: FocusState<Bool>.Binding?
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search")
        searchField.delegate = context.coordinator
        
        // Make search field larger and more prominent
        searchField.font = .systemFont(ofSize: 17, weight: .regular)
        searchField.controlSize = .large
        
        // Remove borders and background for custom styling
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.bezelStyle = .roundedBezel
        
        // Hide the built-in search icon since we have our own
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.isTransparent = true
        }
        
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFocused?.wrappedValue == true, nsView.window?.firstResponder != nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused?.wrappedValue = true
            parent.onFocusChange(true)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused?.wrappedValue = false
            parent.onFocusChange(false)
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Arrow keys and Escape are swallowed here so the field's text view does not
            // act on them; the panel's key monitor handles navigation. Return is left to
            // the search field's default handling.
            if commandSelector == #selector(NSResponder.moveDown(_:))
                || commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                return true
            }
            return false
        }
    }
}

// pickerTitle provided by ContentType+UI.swift

// MARK: - Content Type Filter Chip

// `ContentTypeFilterChip` now lives in ContentTypeFilterChip.swift.

// MARK: - Content Type Picker

/// Compact picker shown via ⌘P listing the content types present in the
/// current clipboard history. Selecting a row sets the filter; "All" clears it.
public struct ContentTypePickerView: View {
    let availableTypes: [ContentType]
    let selectedType: ContentType?
    let onSelect: (ContentType?) -> Void
    let onCancel: () -> Void

    public init(
        availableTypes: [ContentType],
        selectedType: ContentType?,
        onSelect: @escaping (ContentType?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.availableTypes = availableTypes
        self.selectedType = selectedType
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Filter by Content Type")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    PickerRow(
                        icon: "circle.dashed",
                        title: "All",
                        tint: .secondary,
                        isSelected: selectedType == nil
                    ) {
                        onSelect(nil)
                    }

                    if !availableTypes.isEmpty {
                        Divider().padding(.vertical, 4)
                    }

                    ForEach(availableTypes, id: \.self) { type in
                        PickerRow(
                            icon: type.systemImageName,
                            title: type.displayTitle,
                            tint: type.tint,
                            isSelected: selectedType == type
                        ) {
                            onSelect(type)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 240)
        .onExitCommand(perform: onCancel)
    }

    private struct PickerRow: View {
        let icon: String
        let title: String
        let tint: Color
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
