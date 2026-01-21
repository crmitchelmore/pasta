import AppKit
import PastaCore
import SwiftUI

// MARK: - Quick Search View (Spotlight-like)

public struct QuickSearchView: View {
    @ObservedObject private var manager = QuickSearchManager.shared
    private let onDismiss: () -> Void
    private let onPaste: (ClipboardEntry) -> Void
    
    @FocusState private var isSearchFocused: Bool
    
    public init(
        onDismiss: @escaping () -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void
    ) {
        self.onDismiss = onDismiss
        self.onPaste = onPaste
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Search field
            searchField
            
            // Quick filters
            filterBar
            
            Divider()
                .opacity(0.5)
            
            // Results
            if manager.results.isEmpty && !manager.query.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(width: 680, height: max(400, min(500, CGFloat(100 + manager.results.count * 52))))
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            manager.prepareForSearch()
            isSearchFocused = true
        }
        .onChange(of: manager.query) { _, _ in
            manager.searchQueryChanged()
        }
        .onChange(of: manager.selectedFilter) { _, _ in
            manager.searchQueryChanged()
        }
    }
    
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            
            TextField("Search clipboard history...", text: $manager.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit {
                    if let entry = manager.selectedEntry {
                        onPaste(entry)
                        onDismiss()
                    }
                }
            
            if !manager.query.isEmpty {
                Button {
                    manager.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Text("⌘\(manager.results.isEmpty ? "" : "1-9")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
    
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "All",
                    icon: "tray.full",
                    isSelected: manager.selectedFilter == nil,
                    count: nil
                ) {
                    manager.selectedFilter = nil
                }
                
                ForEach(manager.availableFilters, id: \.type) { filter in
                    FilterChip(
                        title: filter.type.displayTitle,
                        icon: filter.type.systemImageName,
                        isSelected: manager.selectedFilter == filter.type,
                        count: filter.count
                    ) {
                        manager.selectedFilter = filter.type
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No results for \"\(manager.query)\"")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
    
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(manager.results.prefix(9).enumerated()), id: \.element.id) { index, entry in
                        QuickSearchRow(
                            entry: entry,
                            index: index + 1,
                            isSelected: manager.selectedIndex == index,
                            query: manager.query
                        )
                        .id(entry.id)
                        .onTapGesture {
                            onPaste(entry)
                            onDismiss()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: manager.selectedIndex) { _, newIndex in
                if let entry = manager.results[safe: newIndex] {
                    proxy.scrollTo(entry.id, anchor: .center)
                }
            }
        }
        .onKeyPress(.downArrow) {
            manager.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            manager.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            if let entry = manager.selectedEntry {
                onPaste(entry)
                onDismiss()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command),
                  let digit = Int(press.characters),
                  digit >= 1 && digit <= 9 else {
                return .ignored
            }
            let index = digit - 1
            if let entry = manager.results[safe: index] {
                onPaste(entry)
                onDismiss()
            }
            return .handled
        }
    }
}

// MARK: - Quick Search Row

private struct QuickSearchRow: View {
    let entry: ClipboardEntry
    let index: Int
    let isSelected: Bool
    let query: String
    
    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: entry.contentType.systemImageName)
                .font(.title3)
                .foregroundStyle(entry.contentType.tint)
                .frame(width: 28)
            
            // Content preview
            VStack(alignment: .leading, spacing: 2) {
                Text(previewText)
                    .lineLimit(1)
                    .font(.body)
                
                HStack(spacing: 6) {
                    Text(entry.contentType.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    if let app = entry.sourceApp?.appDisplayName {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(app)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(entry.timestamp.relativeFormatted)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Keyboard shortcut hint
            Text("⌘\(index)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    
    private var previewText: String {
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = trimmed.components(separatedBy: .newlines).joined(separator: " ")
        return singleLine.isEmpty ? "(empty)" : String(singleLine.prefix(100))
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let count: Int?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Visual Effect View

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Date Formatting Extension

private extension Date {
    var relativeFormatted: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - String Extensions

private extension String {
    /// Extracts a readable app name from a bundle identifier
    var appDisplayName: String {
        let parts = self.split(separator: ".")
        if let last = parts.last {
            return String(last).capitalized
        }
        return self
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
