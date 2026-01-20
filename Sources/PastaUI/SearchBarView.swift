import AppKit
import PastaCore
import SwiftUI

public struct SearchBarView: View {
    @Binding private var query: String
    @Binding private var isFuzzy: Bool
    @Binding private var contentType: ContentType?
    @Binding private var sourceAppFilter: String

    private let resultCount: Int
    private let onOpenSettings: () -> Void
    private let searchFocused: FocusState<Bool>.Binding

    public init(
        query: Binding<String>,
        isFuzzy: Binding<Bool>,
        contentType: Binding<ContentType?>,
        resultCount: Int,
        sourceAppFilter: Binding<String>,
        onOpenSettings: @escaping () -> Void,
        searchFocused: FocusState<Bool>.Binding
    ) {
        _query = query
        _isFuzzy = isFuzzy
        _contentType = contentType
        self.resultCount = resultCount
        _sourceAppFilter = sourceAppFilter
        self.onOpenSettings = onOpenSettings
        self.searchFocused = searchFocused
    }

    public var body: some View {
        HStack(spacing: 12) {
            SearchField(text: $query, isFocused: searchFocused)
                .frame(minWidth: 220)

            SearchField(text: $sourceAppFilter, isFocused: nil)
                .frame(width: 160)
                .accessibilityLabel("Source app filter")

            Picker("Type", selection: $contentType) {
                Text("All").tag(ContentType?.none)
                ForEach(ContentType.allCases, id: \.self) { type in
                    Text(type.pickerTitle).tag(Optional(type))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Content type")

            Picker("Match", selection: $isFuzzy) {
                Text("Exact").tag(false)
                Text("Fuzzy").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Search mode")

            Text("\(resultCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Result count")

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }
}

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search")
        searchField.delegate = context.coordinator
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
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused?.wrappedValue = false
        }
    }
}

// pickerTitle provided by ContentType+UI.swift
