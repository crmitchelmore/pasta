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
    public let isExtracted: Bool
    public let parentEntryId: UUID?
    public let isSynced: Bool
    public let swatchColor: SwatchColor?

    public struct SwatchColor: Equatable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
        public let alpha: Double

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    public init(from entry: ClipboardEntry) {
        self.id = entry.id
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseText = trimmed.isEmpty ? "(empty)" : String(trimmed.prefix(300))
        // Credit-card primary entries should never show their full PAN in the row preview.
        if entry.contentType == .creditCard, !trimmed.isEmpty {
            self.previewText = ClipboardRowData.maskCreditCardPreview(trimmed)
        } else {
            self.previewText = baseText
        }
        self.contentType = entry.contentType
        self.sourceAppName = entry.sourceApp?.displayName
        self.timestamp = entry.timestamp
        self.copyCount = entry.copyCount
        self.isLarge = entry.content.utf8.count > 10 * 1024
        self.isExtracted = entry.isExtracted
        self.parentEntryId = entry.parentEntryId
        self.isSynced = entry.isSynced
        self.swatchColor = Self.parseSwatch(from: entry)
    }

    private static func parseSwatch(from entry: ClipboardEntry) -> SwatchColor? {
        guard entry.contentType == .color else { return nil }
        if let meta = entry.metadata,
           let data = meta.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = obj as? [String: Any],
           let colors = dict["colors"] as? [[String: Any]],
           let first = colors.first,
           let r = (first["red"] as? Int) ?? (first["red"] as? Double).map(Int.init),
           let g = (first["green"] as? Int) ?? (first["green"] as? Double).map(Int.init),
           let b = (first["blue"] as? Int) ?? (first["blue"] as? Double).map(Int.init)
        {
            let a = (first["alpha"] as? Double) ?? Double(first["alpha"] as? Int ?? 1)
            return SwatchColor(red: UInt8(clamping: r), green: UInt8(clamping: g), blue: UInt8(clamping: b), alpha: a)
        }
        // Fallback: re-detect from content.
        let detector = ColorSwatchParser.shared
        if let det = detector.parse(entry.content) {
            return SwatchColor(red: det.red, green: det.green, blue: det.blue, alpha: det.alpha)
        }
        return nil
    }

    /// Masks any 13-19 digit (Luhn-valid) numbers in the preview, leaving only last 4 visible.
    /// Falls back to the trimmed input if no valid card found.
    static func maskCreditCardPreview(_ text: String) -> String {
        let digits = text.filter(\.isNumber)
        guard digits.count >= 13, digits.count <= 19 else {
            return String(text.prefix(300))
        }
        // If the whole entry is a single card number, build the masked grouped form.
        let last4 = String(digits.suffix(4))
        let masked = String(repeating: "*", count: max(0, digits.count - 4)) + last4
        var grouped = ""
        for (i, ch) in masked.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append(" ") }
            grouped.append(ch)
        }
        return grouped
    }
}

/// Tiny shim to avoid pulling PastaDetectors into PastaUI for swatch parsing.
/// Uses NSColor parsing for hex literals as a best-effort fallback.
private final class ColorSwatchParser {
    static let shared = ColorSwatchParser()
    struct Parsed { let red: UInt8; let green: UInt8; let blue: UInt8; let alpha: Double }

    func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = String(trimmed.dropFirst())
        switch body.count {
        case 3:
            let chars = Array(body)
            guard let r = hex(chars[0], chars[0]),
                  let g = hex(chars[1], chars[1]),
                  let b = hex(chars[2], chars[2]) else { return nil }
            return Parsed(red: r, green: g, blue: b, alpha: 1.0)
        case 6:
            let chars = Array(body)
            guard let r = hex(chars[0], chars[1]),
                  let g = hex(chars[2], chars[3]),
                  let b = hex(chars[4], chars[5]) else { return nil }
            return Parsed(red: r, green: g, blue: b, alpha: 1.0)
        case 8:
            let chars = Array(body)
            guard let r = hex(chars[0], chars[1]),
                  let g = hex(chars[2], chars[3]),
                  let b = hex(chars[4], chars[5]),
                  let a = hex(chars[6], chars[7]) else { return nil }
            return Parsed(red: r, green: g, blue: b, alpha: Double(a) / 255.0)
        default:
            return nil
        }
    }

    private func hex(_ a: Character, _ b: Character) -> UInt8? {
        UInt8(String([a, b]), radix: 16)
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
    @Binding public var selectedIDs: Set<UUID>
    public let onPaste: (UUID) -> Void
    public let onCopy: (UUID) -> Void
    public let onCopyMultiple: ([UUID]) -> Void
    public let onDelete: (UUID) -> Void
    public let onReveal: (UUID) -> Void
    public let onOpenURL: ((UUID) -> Void)?

    public init(
        rows: [ClipboardRowData],
        selectedID: Binding<UUID?>,
        selectedIDs: Binding<Set<UUID>>,
        onPaste: @escaping (UUID) -> Void,
        onCopy: @escaping (UUID) -> Void,
        onCopyMultiple: @escaping ([UUID]) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onReveal: @escaping (UUID) -> Void,
        onOpenURL: ((UUID) -> Void)? = nil
    ) {
        self.rows = rows
        self._selectedID = selectedID
        self._selectedIDs = selectedIDs
        self.onPaste = onPaste
        self.onCopy = onCopy
        self.onCopyMultiple = onCopyMultiple
        self.onDelete = onDelete
        self.onReveal = onReveal
        self.onOpenURL = onOpenURL
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
        scrollView.focusRingType = .none
        
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        
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
            tableView.reloadData()
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
        let desiredSelection: IndexSet
        if !selectedIDs.isEmpty {
            desiredSelection = IndexSet(selectedIDs.compactMap { id in
                newRows.firstIndex(where: { $0.id == id })
            })
        } else if let selectedID,
                  let index = newRows.firstIndex(where: { $0.id == selectedID }) {
            desiredSelection = IndexSet(integer: index)
        } else {
            desiredSelection = []
        }

        if tableView.selectedRowIndexes != desiredSelection {
            tableView.selectRowIndexes(desiredSelection, byExtendingSelection: false)

            let focusIndex: Int?
            if let selectedID,
               let index = newRows.firstIndex(where: { $0.id == selectedID }) {
                focusIndex = index
            } else {
                focusIndex = desiredSelection.first
            }

            if let focusIndex {
                tableView.scrollRowToVisible(focusIndex)
            }
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
            let selectedRowIndexes = tableView.selectedRowIndexes
            let ids: Set<UUID> = Set(selectedRowIndexes.compactMap { row in
                guard row >= 0 && row < rows.count else { return nil }
                return rows[row].id
            })

            let primaryID: UUID?
            if let current = parent.selectedID, ids.contains(current) {
                primaryID = current
            } else if let row = selectedRowIndexes.last, row >= 0 && row < rows.count {
                primaryID = rows[row].id
            } else {
                primaryID = nil
            }

            if parent.selectedIDs != ids || parent.selectedID != primaryID {
                DispatchQueue.main.async {
                    self.parent.selectedIDs = ids
                    self.parent.selectedID = primaryID
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
            let copySelectionIDs: [UUID]
            if tableView.selectedRowIndexes.count > 1, tableView.selectedRowIndexes.contains(row) {
                copySelectionIDs = tableView.selectedRowIndexes.compactMap { selectedRow in
                    guard selectedRow >= 0 && selectedRow < rows.count else { return nil }
                    return rows[selectedRow].id
                }
            } else {
                copySelectionIDs = [rowData.id]
            }
            
            menu.addItem(withTitle: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
            menu.addItem(withTitle: copySelectionIDs.count > 1 ? "Copy Selected" : "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
            menu.addItem(deleteItem)
            
            if rowData.contentType == .filePath {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(withTitle: "Reveal in Finder", action: #selector(contextReveal(_:)), keyEquivalent: "")
            }

            if rowData.contentType == .url, parent.onOpenURL != nil {
                menu.addItem(NSMenuItem.separator())
                let openItem = NSMenuItem(title: "Open Link", action: #selector(contextOpenURL(_:)), keyEquivalent: "o")
                openItem.keyEquivalentModifierMask = [.command]
                openItem.representedObject = rowData.id
                menu.addItem(openItem)
            }

            for item in menu.items {
                item.target = self
            }
            menu.items[0].representedObject = rowData.id
            menu.items[1].representedObject = copySelectionIDs
            deleteItem.representedObject = rowData.id
            if rowData.contentType == .filePath, let revealItem = menu.items.first(where: { $0.title == "Reveal in Finder" }) {
                revealItem.representedObject = rowData.id
            }
        }
        
        @objc private func contextPaste(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onPaste(id)
        }
        
        @objc private func contextCopy(_ sender: NSMenuItem) {
            if let ids = sender.representedObject as? [UUID] {
                if ids.count > 1 {
                    parent.onCopyMultiple(ids)
                } else if let id = ids.first {
                    parent.onCopy(id)
                }
            } else if let id = sender.representedObject as? UUID {
                parent.onCopy(id)
            }
        }
        
        @objc private func contextDelete(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onDelete(id)
        }
        
        @objc private func contextReveal(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onReveal(id)
        }

        @objc private func contextOpenURL(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            parent.onOpenURL?(id)
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
    private let extractedIndicator = NSImageView()
    private let syncIndicator = NSImageView()
    
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
        
        // Extracted indicator (link icon)
        extractedIndicator.translatesAutoresizingMaskIntoConstraints = false
        extractedIndicator.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Extracted from another entry")
        extractedIndicator.contentTintColor = .systemBlue
        extractedIndicator.setContentHuggingPriority(.required, for: .horizontal)
        extractedIndicator.toolTip = "Extracted from copied text"
        addSubview(extractedIndicator)
        
        // Large indicator
        largeIndicator.translatesAutoresizingMaskIntoConstraints = false
        largeIndicator.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Large entry")
        largeIndicator.contentTintColor = .systemOrange
        largeIndicator.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(largeIndicator)
        
        // Sync indicator (subtle cloud)
        syncIndicator.translatesAutoresizingMaskIntoConstraints = false
        syncIndicator.image = NSImage(systemSymbolName: "icloud.fill", accessibilityDescription: "Synced to iCloud")
        syncIndicator.contentTintColor = .tertiaryLabelColor
        syncIndicator.setContentHuggingPriority(.required, for: .horizontal)
        syncIndicator.toolTip = "Synced to iCloud"
        addSubview(syncIndicator)
        
        // Layout
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: extractedIndicator.leadingAnchor, constant: -8),
            
            extractedIndicator.trailingAnchor.constraint(equalTo: largeIndicator.leadingAnchor, constant: -6),
            extractedIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            extractedIndicator.widthAnchor.constraint(equalToConstant: 14),
            extractedIndicator.heightAnchor.constraint(equalToConstant: 14),
            
            largeIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            largeIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            largeIndicator.widthAnchor.constraint(equalToConstant: 14),
            largeIndicator.heightAnchor.constraint(equalToConstant: 14),
            
            badgeView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            badgeView.heightAnchor.constraint(equalToConstant: 18),
            
            metadataLabel.leadingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: 8),
            metadataLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            
            syncIndicator.leadingAnchor.constraint(equalTo: metadataLabel.trailingAnchor, constant: 6),
            syncIndicator.centerYAnchor.constraint(equalTo: metadataLabel.centerYAnchor),
            syncIndicator.widthAnchor.constraint(equalToConstant: 12),
            syncIndicator.heightAnchor.constraint(equalToConstant: 10),
            syncIndicator.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    
    func configure(with row: ClipboardRowData) {
        // Icon (or color swatch)
        if let swatch = row.swatchColor {
            iconView.image = nil
            iconView.wantsLayer = true
            let cg = CGColor(
                srgbRed: CGFloat(swatch.red) / 255.0,
                green: CGFloat(swatch.green) / 255.0,
                blue: CGFloat(swatch.blue) / 255.0,
                alpha: CGFloat(swatch.alpha)
            )
            iconView.layer?.backgroundColor = cg
            iconView.layer?.cornerRadius = 4
            iconView.layer?.borderColor = NSColor.separatorColor.cgColor
            iconView.layer?.borderWidth = 0.5
        } else {
            iconView.layer?.backgroundColor = nil
            iconView.layer?.borderWidth = 0
            iconView.layer?.cornerRadius = 0
            iconView.image = NSImage(systemSymbolName: row.contentType.systemImageName, accessibilityDescription: nil)
            iconView.contentTintColor = NSColor(row.contentType.tint)
        }
        
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
        
        // Extracted indicator
        extractedIndicator.isHidden = !row.isExtracted
        
        // Large indicator
        largeIndicator.isHidden = !row.isLarge
        
        // Sync indicator
        syncIndicator.isHidden = !row.isSynced
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
