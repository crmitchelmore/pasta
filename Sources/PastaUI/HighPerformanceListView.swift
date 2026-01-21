import AppKit
import PastaCore
import SwiftUI

// MARK: - Row Data Model

/// Lightweight data for rendering a single row
public struct ClipboardRowData: Equatable {
    public let id: UUID
    public let previewText: String
    public let contentType: ContentType
    public let sourceAppName: String?
    public let timestamp: Date
    public let copyCount: Int
    public let isLarge: Bool
    
    public init(from entry: ClipboardEntry) {
        self.id = entry.id
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.previewText = trimmed.isEmpty ? "(empty)" : String(trimmed.prefix(300))
        self.contentType = entry.contentType
        self.sourceAppName = entry.sourceApp?.displayName
        self.timestamp = entry.timestamp
        self.copyCount = entry.copyCount
        self.isLarge = entry.content.utf8.count > 10 * 1024
    }
}

private extension String {
    var displayName: String {
        let parts = self.split(separator: ".")
        if let last = parts.last {
            return String(last).capitalized
        }
        return self
    }
}

// MARK: - NSTableView Wrapper

/// High-performance list using NSTableView with cell reuse
public struct HighPerformanceListView: NSViewRepresentable {
    public let rows: [ClipboardRowData]
    @Binding public var selectedID: UUID?
    public let onPaste: (UUID) -> Void
    public let onCopy: (UUID) -> Void
    public let onDelete: (UUID) -> Void
    public let onReveal: (UUID) -> Void
    
    public init(
        rows: [ClipboardRowData],
        selectedID: Binding<UUID?>,
        onPaste: @escaping (UUID) -> Void,
        onCopy: @escaping (UUID) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onReveal: @escaping (UUID) -> Void
    ) {
        self.rows = rows
        self._selectedID = selectedID
        self.onPaste = onPaste
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onReveal = onReveal
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        
        // Single column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        
        // Context menu
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        
        return scrollView
    }
    
    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        
        let oldRows = context.coordinator.rows
        let newRows = rows
        
        // Update coordinator data
        context.coordinator.rows = newRows
        context.coordinator.parent = self
        
        // Smart diff update for performance
        if oldRows.map(\.id) != newRows.map(\.id) {
            // Structure changed - full reload
            let selectedRow = tableView.selectedRow
            tableView.reloadData()
            
            // Restore selection
            if let selectedID = selectedID,
               let idx = newRows.firstIndex(where: { $0.id == selectedID }) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            } else if selectedRow >= 0 && selectedRow < newRows.count {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            }
        } else if oldRows != newRows {
            // Same structure, content changed - update visible rows only
            let visibleRect = tableView.visibleRect
            let visibleRows = tableView.rows(in: visibleRect)
            for row in visibleRows.lowerBound..<visibleRows.upperBound {
                if row < newRows.count && (row >= oldRows.count || oldRows[row] != newRows[row]) {
                    tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
        
        // Sync selection from SwiftUI to table
        if let selectedID = selectedID {
            if let idx = newRows.firstIndex(where: { $0.id == selectedID }) {
                if tableView.selectedRow != idx {
                    tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    tableView.scrollRowToVisible(idx)
                }
            }
        } else if tableView.selectedRow != -1 {
            tableView.deselectAll(nil)
        }
    }
    
    // MARK: - Coordinator
    
    public class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var parent: HighPerformanceListView
        var rows: [ClipboardRowData] = []
        weak var tableView: NSTableView?
        
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("ClipboardCell")
        
        init(parent: HighPerformanceListView) {
            self.parent = parent
            self.rows = parent.rows
        }
        
        // MARK: - DataSource
        
        public func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }
        
        // MARK: - Delegate
        
        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }
            let rowData = rows[row]
            
            // Reuse or create cell
            let cell: ClipboardCellView
            if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? ClipboardCellView {
                cell = reused
            } else {
                cell = ClipboardCellView()
                cell.identifier = Self.cellIdentifier
            }
            
            cell.configure(with: rowData)
            return cell
        }
        
        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            56 // Fixed height for performance
        }
        
        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRow = tableView.selectedRow
            
            if selectedRow >= 0 && selectedRow < rows.count {
                let id = rows[selectedRow].id
                if parent.selectedID != id {
                    DispatchQueue.main.async {
                        self.parent.selectedID = id
                    }
                }
            } else {
                if parent.selectedID != nil {
                    DispatchQueue.main.async {
                        self.parent.selectedID = nil
                    }
                }
            }
        }
        
        // MARK: - Actions
        
        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0 && row < rows.count else { return }
            parent.onPaste(rows[row].id)
        }
        
        // MARK: - Context Menu
        
        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0 && row < rows.count else { return }
            
            let rowData = rows[row]
            
            menu.addItem(withTitle: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
            menu.addItem(deleteItem)
            
            if rowData.contentType == .filePath {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "Reveal in Finder", action: #selector(contextReveal(_:)), keyEquivalent: "")
            }
            
            for item in menu.items {
                item.target = self
                item.representedObject = rowData.id
            }
        }
        
        @objc private func contextPaste(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onPaste(id)
        }
        
        @objc private func contextCopy(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onCopy(id)
        }
        
        @objc private func contextDelete(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onDelete(id)
        }
        
        @objc private func contextReveal(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onReveal(id)
        }
    }
}

// MARK: - Custom Cell View

private final class ClipboardCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let badgeView = NSTextField(labelWithString: "")
    private let largeIndicator = NSImageView()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconView)
        
        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)
        
        // Metadata
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(metadataLabel)
        
        // Badge
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeView.isBordered = false
        badgeView.drawsBackground = true
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 4
        badgeView.alignment = .center
        badgeView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(badgeView)
        
        // Large indicator
        largeIndicator.translatesAutoresizingMaskIntoConstraints = false
        largeIndicator.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Large entry")
        largeIndicator.contentTintColor = .systemOrange
        largeIndicator.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(largeIndicator)
        
        // Layout
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: largeIndicator.leadingAnchor, constant: -8),
            
            largeIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            largeIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            largeIndicator.widthAnchor.constraint(equalToConstant: 14),
            largeIndicator.heightAnchor.constraint(equalToConstant: 14),
            
            badgeView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            badgeView.heightAnchor.constraint(equalToConstant: 18),
            
            metadataLabel.leadingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: 8),
            metadataLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    
    func configure(with row: ClipboardRowData) {
        // Icon
        iconView.image = NSImage(systemSymbolName: row.contentType.systemImageName, accessibilityDescription: nil)
        iconView.contentTintColor = NSColor(row.contentType.tint)
        
        // Title - fixed layout, no movement
        titleLabel.stringValue = row.previewText
        
        // Badge
        badgeView.stringValue = " \(row.contentType.badgeTitle) "
        let tint = NSColor(row.contentType.tint)
        badgeView.textColor = tint
        badgeView.backgroundColor = tint.withAlphaComponent(0.15)
        
        // Metadata
        var meta: [String] = []
        if let app = row.sourceAppName {
            meta.append(app)
        }
        meta.append(RelativeDateFormatter.shared.string(from: row.timestamp))
        if row.copyCount > 1 {
            meta.append("×\(row.copyCount)")
        }
        metadataLabel.stringValue = meta.joined(separator: " • ")
        
        // Large indicator
        largeIndicator.isHidden = !row.isLarge
    }
}

// MARK: - Relative Date Formatter (cached)

private final class RelativeDateFormatter {
    static let shared = RelativeDateFormatter()
    
    private let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    
    func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}
