import AppKit
import PastaCore
import SwiftUI

public struct SearchBarView: View {
    @Binding private var query: String
    @Binding private var contentType: ContentType?
    @Binding private var sourceAppFilter: String
    @Binding private var showContentTypePicker: Bool

    private let resultCount: Int
    private let suggestions: [SearchSuggestion]
    private let availableContentTypes: [ContentType]
    private let onOpenSettings: () -> Void
    private let searchFocused: FocusState<Bool>.Binding

    @State private var isFieldFocused: Bool = false

    public init(
        query: Binding<String>,
        contentType: Binding<ContentType?>,
        resultCount: Int,
        sourceAppFilter: Binding<String>,
        suggestions: [SearchSuggestion] = [],
        availableContentTypes: [ContentType] = [],
        showContentTypePicker: Binding<Bool> = .constant(false),
        onOpenSettings: @escaping () -> Void,
        searchFocused: FocusState<Bool>.Binding
    ) {
        _query = query
        _contentType = contentType
        self.resultCount = resultCount
        _sourceAppFilter = sourceAppFilter
        self.suggestions = suggestions
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
                SearchFieldWithSuggestions(
                    text: $query,
                    placeholder: "Search your clipboard history...",
                    suggestions: suggestions,
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

                // Result count badge — passive information, so it reads as
                // secondary rather than competing with the accent chip.
                Text(Self.resultCountLabel(resultCount))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PastaTheme.Spacing.md)
                    .padding(.vertical, PastaTheme.Spacing.xs)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .padding(.trailing, PastaTheme.Spacing.lg)
                    .contentTransition(.numericText(value: Double(resultCount)))
                    .accessibilityLabel("\(Self.resultCountLabel(resultCount)) results")
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

// MARK: - Search Suggestions

public struct SearchSuggestion: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let icon: String
    public let category: Category
    
    public enum Category: String {
        case recent = "Recent"
        case content = "Content"
        case sourceApp = "App"
        case contentType = "Type"
    }
    
    public init(id: String = UUID().uuidString, text: String, icon: String, category: Category) {
        self.id = id
        self.text = text
        self.icon = icon
        self.category = category
    }
}

// MARK: - Search Field with Suggestions

private struct SearchFieldWithSuggestions: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let suggestions: [SearchSuggestion]
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
        
        // Update suggestions in coordinator
        context.coordinator.updateSuggestions(suggestions, for: nsView)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
        private let parent: SearchFieldWithSuggestions
        private var suggestionsWindow: NSWindow?
        private var tableView: NSTableView?
        private var currentSuggestions: [SearchSuggestion] = []
        private var filteredSuggestions: [SearchSuggestion] = []
        private weak var searchField: NSSearchField?

        init(_ parent: SearchFieldWithSuggestions) {
            self.parent = parent
        }

        func updateSuggestions(_ suggestions: [SearchSuggestion], for searchField: NSSearchField) {
            self.searchField = searchField
            self.currentSuggestions = suggestions
            filterSuggestions()
        }
        
        private func filterSuggestions() {
            let query = parent.text.lowercased().trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                // Show recent suggestions when empty
                filteredSuggestions = currentSuggestions.filter { $0.category == .recent }.prefix(8).map { $0 }
            } else {
                // Filter by query
                filteredSuggestions = currentSuggestions.filter { suggestion in
                    suggestion.text.lowercased().contains(query)
                }.prefix(10).map { $0 }
            }
            tableView?.reloadData()
            updateWindowVisibility()
        }
        
        private func updateWindowVisibility() {
            guard let searchField else { return }
            
            if filteredSuggestions.isEmpty {
                hideSuggestionsWindow()
                return
            }
            
            if suggestionsWindow == nil {
                createSuggestionsWindow(for: searchField)
            }
            
            positionSuggestionsWindow(for: searchField)
            suggestionsWindow?.orderFront(nil)
        }
        
        private func createSuggestionsWindow(for searchField: NSSearchField) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            
            // Create table view for suggestions
            let tableView = NSTableView()
            tableView.headerView = nil
            tableView.rowHeight = 32
            tableView.intercellSpacing = NSSize(width: 0, height: 2)
            tableView.backgroundColor = .clear
            tableView.selectionHighlightStyle = .regular
            tableView.dataSource = self
            tableView.delegate = self
            tableView.target = self
            tableView.doubleAction = #selector(suggestionSelected)
            
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
            column.width = 380
            tableView.addTableColumn(column)
            
            let scrollView = NSScrollView()
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            
            // Container with rounded corners and blur
            let container = NSVisualEffectView()
            container.material = .popover
            container.state = .active
            container.wantsLayer = true
            container.layer?.cornerRadius = 10
            container.layer?.masksToBounds = true
            
            scrollView.frame = container.bounds
            scrollView.autoresizingMask = [.width, .height]
            container.addSubview(scrollView)
            
            window.contentView = container
            
            self.suggestionsWindow = window
            self.tableView = tableView
        }
        
        private func positionSuggestionsWindow(for searchField: NSSearchField) {
            guard let window = suggestionsWindow,
                  let parentWindow = searchField.window else { return }
            
            let fieldRect = searchField.convert(searchField.bounds, to: nil)
            let screenRect = parentWindow.convertToScreen(fieldRect)
            
            let height = min(CGFloat(filteredSuggestions.count) * 34 + 8, 250)
            let width = max(searchField.bounds.width, 300)
            
            window.setFrame(
                NSRect(
                    x: screenRect.minX,
                    y: screenRect.minY - height - 4,
                    width: width,
                    height: height
                ),
                display: true
            )
        }
        
        private func hideSuggestionsWindow() {
            suggestionsWindow?.orderOut(nil)
        }
        
        @objc private func suggestionSelected() {
            guard let tableView,
                  tableView.selectedRow >= 0,
                  tableView.selectedRow < filteredSuggestions.count else { return }
            
            let suggestion = filteredSuggestions[tableView.selectedRow]
            parent.text = suggestion.text
            hideSuggestionsWindow()
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused?.wrappedValue = true
            parent.onFocusChange(true)
            filterSuggestions()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
            filterSuggestions()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused?.wrappedValue = false
            parent.onFocusChange(false)
            // Delay hiding to allow click on suggestion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.hideSuggestionsWindow()
            }
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let tableView, filteredSuggestions.count > 0 {
                    let newRow = min(tableView.selectedRow + 1, filteredSuggestions.count - 1)
                    tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                    tableView.scrollRowToVisible(newRow)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if let tableView, tableView.selectedRow > 0 {
                    let newRow = tableView.selectedRow - 1
                    tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                    tableView.scrollRowToVisible(newRow)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let tableView, tableView.selectedRow >= 0 {
                    suggestionSelected()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                hideSuggestionsWindow()
                return true
            }
            return false
        }
        
        // MARK: - NSTableViewDataSource
        
        func numberOfRows(in tableView: NSTableView) -> Int {
            filteredSuggestions.count
        }
        
        // MARK: - NSTableViewDelegate
        
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < filteredSuggestions.count else { return nil }
            let suggestion = filteredSuggestions[row]
            
            let cellView = NSTableCellView()
            
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
            
            // Icon
            let iconView = NSImageView()
            iconView.image = NSImage(systemSymbolName: suggestion.icon, accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(iconView)
            
            // Text
            let textField = NSTextField(labelWithString: suggestion.text)
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(textField)
            
            // Category badge
            let badge = NSTextField(labelWithString: suggestion.category.rawValue)
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .tertiaryLabelColor
            badge.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(badge)
            
            stack.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cellView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: cellView.bottomAnchor)
            ])
            
            return cellView
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

// MARK: - Result count label

extension SearchBarView {
    /// The main panel never displays more than this many rows at once (the
    /// preload/search paths cap their fetches here), so a count equal to the
    /// cap means "at least this many", not an exact total.
    public static let resultCountCap = 200

    /// "42" below the cap, "200+" once the displayed count reaches it.
    static func resultCountLabel(_ count: Int, cap: Int = resultCountCap) -> String {
        count >= cap ? "\(cap)+" : "\(count)"
    }
}
