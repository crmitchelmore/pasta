import AppKit
import PastaCore
import SwiftUI

public struct SearchBarView: View {
    @Binding private var query: String
    @Binding private var filterSelection: FilterSelection?
    @Binding private var showContentTypePicker: Bool

    private let resultCount: Int
    private let availableContentTypes: [ContentType]
    private let onOpenSettings: () -> Void
    private let searchFocused: FocusState<Bool>.Binding

    @State private var isFieldFocused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        query: Binding<String>,
        filterSelection: Binding<FilterSelection?>,
        resultCount: Int,
        availableContentTypes: [ContentType] = [],
        showContentTypePicker: Binding<Bool> = .constant(false),
        onOpenSettings: @escaping () -> Void,
        searchFocused: FocusState<Bool>.Binding
    ) {
        _query = query
        _filterSelection = filterSelection
        self.resultCount = resultCount
        self.availableContentTypes = availableContentTypes
        _showContentTypePicker = showContentTypePicker
        self.onOpenSettings = onOpenSettings
        self.searchFocused = searchFocused
    }

    /// The chip and ⌘P picker only know about content types; map their
    /// choice onto the shared selection. Re-picking URL while a specific
    /// domain is active keeps that domain (the picker already shows URL as
    /// selected in that state).
    private func applyContentType(_ type: ContentType?) {
        if type == .url, case .domain = filterSelection { return }
        filterSelection = type.map(FilterSelection.type) ?? .all
    }

    private static let fieldHeight: CGFloat = 36

    /// Focus/clear changes fade briefly; nothing moves or scales, and even
    /// the fade is dropped when the user asks for reduced motion.
    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.15)
    }

    public var body: some View {
        HStack(spacing: PastaTheme.Spacing.lg) {
            searchFieldRow
                .frame(height: Self.fieldHeight)
                .frame(maxWidth: .infinity)
                .background(fieldBackground)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                .animation(chromeAnimation, value: isFieldFocused)

            Button(action: onOpenSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: Self.fieldHeight, height: Self.fieldHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, PastaTheme.Spacing.xs)
    }

    private var fieldBackground: some View {
        let shape = RoundedRectangle(cornerRadius: PastaTheme.Radius.large, style: .continuous)
        return shape
            .fill(.regularMaterial)
            .overlay {
                shape.strokeBorder(
                    isFieldFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
            }
    }

    private var searchFieldRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isFieldFocused ? Color.accentColor : .secondary)
                .frame(width: Self.fieldHeight)

            // Search input
            SearchField(
                text: $query,
                placeholder: "Search your clipboard history...",
                isFocused: searchFocused,
                onFocusChange: { focused in
                    withAnimation(chromeAnimation) {
                        isFieldFocused = focused
                    }
                }
            )

            // Clear button (when has text)
            if !query.isEmpty {
                Button {
                    withAnimation(chromeAnimation) {
                        query = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, PastaTheme.Spacing.lg)
                .transition(.opacity)
            }

            // Active content-type filter chip (also visible to confirm
            // selections made via the ⌘P picker or sidebar).
            if let activeType = filterSelection?.contentType {
                ContentTypeFilterChip.activeDismissable(type: activeType, onClear: {
                    withAnimation(chromeAnimation) {
                        applyContentType(nil)
                    }
                })
                .padding(.trailing, PastaTheme.Spacing.md)
                .transition(.opacity)
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
                        selectedType: filterSelection?.contentType,
                        onSelect: { newType in
                            applyContentType(newType)
                            showContentTypePicker = false
                        },
                        onCancel: {
                            showContentTypePicker = false
                        }
                    )
                }
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
