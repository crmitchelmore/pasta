import AppKit
import PastaCore
import SwiftUI

// MARK: - Quick Search View (Spotlight-like)

public struct QuickSearchView: View {
    @ObservedObject private var manager = QuickSearchManager.shared
    private let onDismiss: () -> Void
    private let onPaste: (ClipboardEntry) -> Void
    private let onOpenFullApp: (() -> Void)?
    private let showOpenFullAppButton: Bool
    private let onExecuteCommand: ((Command) async -> CommandResult)?
    
    @FocusState private var isSearchFocused: Bool
    @State private var commandFeedback: String? = nil
    @State private var showingConfirmation: Bool = false
    @State private var pendingConfirmAction: (@Sendable @MainActor () async -> CommandResult)? = nil
    @State private var confirmationMessage: String = ""
    
    public init(
        onDismiss: @escaping () -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void,
        onOpenFullApp: (() -> Void)? = nil,
        showOpenFullAppButton: Bool = false,
        onExecuteCommand: ((Command) async -> CommandResult)? = nil
    ) {
        self.onDismiss = onDismiss
        self.onPaste = onPaste
        self.onOpenFullApp = onOpenFullApp
        self.showOpenFullAppButton = showOpenFullAppButton
        self.onExecuteCommand = onExecuteCommand
    }
    
    public var body: some View {
        QuickSearchKeyHandler(
            onArrowUp: { manager.moveSelection(by: -1) },
            onArrowDown: { manager.moveSelection(by: 1) },
            onReturn: { handleReturn() },
            onEscape: { onDismiss() },
            onCommandNumber: { digit in
                let index = digit - 1
                if manager.isCommandMode {
                    if let command = manager.commandResults[safe: index] {
                        executeCommand(command)
                    }
                } else {
                    if let entry = manager.results[safe: index] {
                        onPaste(entry)
                        onDismiss()
                    }
                }
            }
        ) {
            ZStack {
                VStack(spacing: 0) {
                    // Search field
                    searchField
                    
                    // Quick filters (hidden in command mode)
                    if !manager.isCommandMode {
                        filterBar
                    }
                    
                    Divider()
                        .opacity(0.5)
                    
                    // Results or Commands
                    if manager.isCommandMode {
                        commandsList
                    } else if manager.results.isEmpty && !manager.query.isEmpty {
                        emptyState
                    } else {
                        resultsList
                    }
                    
                    // Command feedback
                    if let feedback = commandFeedback {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(feedback)
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                    }
                }
                .frame(width: 680, height: dynamicHeight)
                .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                
                // Confirmation dialog overlay
                if showingConfirmation {
                    confirmationOverlay
                }
            }
        }
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
    
    private var dynamicHeight: CGFloat {
        let itemCount = manager.isCommandMode ? manager.commandResults.count : manager.results.count
        let baseHeight: CGFloat = manager.isCommandMode ? 80 : 100 // Less for command mode (no filter bar)
        return max(400, min(500, baseHeight + CGFloat(itemCount * 52)))
    }
    
    private func handleReturn() {
        if manager.isCommandMode {
            if let command = manager.selectedCommand {
                executeCommand(command)
            }
        } else {
            pasteSelectedEntry()
        }
    }
    
    private func pasteSelectedEntry() {
        if let entry = manager.selectedEntry {
            onPaste(entry)
            onDismiss()
        }
    }
    
    private func executeCommand(_ command: Command) {
        Task { @MainActor in
            let result: CommandResult
            if let handler = onExecuteCommand {
                result = await handler(command)
            } else {
                result = await CommandRegistry.shared.execute(command)
            }
            
            switch result {
            case .success(let message):
                commandFeedback = message
                // Auto-dismiss after brief feedback
                try? await Task.sleep(nanoseconds: 800_000_000)
                onDismiss()
                
            case .needsConfirmation(let message, let confirmAction):
                confirmationMessage = message
                pendingConfirmAction = confirmAction
                showingConfirmation = true
                
            case .error(let message):
                commandFeedback = "Error: \(message)"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                commandFeedback = nil
                
            case .openMainWindow:
                onDismiss()
                // The handler in AppDelegate will open the main window
                
            case .dismissed:
                onDismiss()
            }
        }
    }
    
    private var confirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                
                Text(confirmationMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        showingConfirmation = false
                        pendingConfirmAction = nil
                    }
                    .keyboardShortcut(.escape)
                    
                    Button("Confirm") {
                        Task { @MainActor in
                            showingConfirmation = false
                            if let action = pendingConfirmAction {
                                let result = await action()
                                pendingConfirmAction = nil
                                
                                if case .success(let message) = result {
                                    commandFeedback = message
                                    try? await Task.sleep(nanoseconds: 800_000_000)
                                    onDismiss()
                                }
                            }
                        }
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
        }
    }
    
    private var commandsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(manager.commandResults.prefix(9).enumerated()), id: \.element.id) { index, command in
                        CommandRow(
                            command: command,
                            index: index + 1,
                            isSelected: manager.selectedIndex == index
                        )
                        .id(command.id)
                        .onTapGesture {
                            executeCommand(command)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: manager.selectedIndex) { _, newIndex in
                if let command = manager.commandResults[safe: newIndex] {
                    proxy.scrollTo(command.id, anchor: .center)
                }
            }
        }
    }
    
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: manager.isCommandMode ? "terminal" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(manager.isCommandMode ? .orange : .secondary)
            
            TextField(manager.isCommandMode ? "Type a command..." : "Search clipboard history... (! for commands)", text: $manager.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit {
                    handleReturn()
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
            
            let hasItems = manager.isCommandMode ? !manager.commandResults.isEmpty : !manager.results.isEmpty
            Text("⌘\(hasItems ? "1-9" : "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            
            if showOpenFullAppButton, let onOpenFullApp {
                Button {
                    onDismiss()
                    onOpenFullApp()
                } label: {
                    Image(systemName: "macwindow")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open full app")
            }
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
    }
}

// MARK: - Key Handler (NSViewRepresentable to capture keys globally)

private struct QuickSearchKeyHandler<Content: View>: NSViewRepresentable {
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void
    let onCommandNumber: (Int) -> Void
    let content: Content
    
    init(
        onArrowUp: @escaping () -> Void,
        onArrowDown: @escaping () -> Void,
        onReturn: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onCommandNumber: @escaping (Int) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onArrowUp = onArrowUp
        self.onArrowDown = onArrowDown
        self.onReturn = onReturn
        self.onEscape = onEscape
        self.onCommandNumber = onCommandNumber
        self.content = content()
    }
    
    func makeNSView(context: Context) -> KeyInterceptingView {
        KeyInterceptingView(
            onArrowUp: onArrowUp,
            onArrowDown: onArrowDown,
            onReturn: onReturn,
            onEscape: onEscape,
            onCommandNumber: onCommandNumber,
            content: content
        )
    }
    
    func updateNSView(_ nsView: KeyInterceptingView, context: Context) {
        nsView.onArrowUp = onArrowUp
        nsView.onArrowDown = onArrowDown
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
        nsView.onCommandNumber = onCommandNumber
        nsView.updateContent(content)
    }
}

private final class KeyInterceptingView: NSView {
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void
    var onCommandNumber: (Int) -> Void
    
    private var hostingView: NSHostingController<AnyView>?
    private var localMonitor: Any?
    
    init<Content: View>(
        onArrowUp: @escaping () -> Void,
        onArrowDown: @escaping () -> Void,
        onReturn: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onCommandNumber: @escaping (Int) -> Void,
        content: Content
    ) {
        self.onArrowUp = onArrowUp
        self.onArrowDown = onArrowDown
        self.onReturn = onReturn
        self.onEscape = onEscape
        self.onCommandNumber = onCommandNumber
        super.init(frame: .zero)
        
        let hosting = NSHostingController(rootView: AnyView(content))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        hostingView = hosting
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateContent<Content: View>(_ content: Content) {
        hostingView?.rootView = AnyView(content)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        // Install monitor when we have a window, remove when we don't
        if window != nil && localMonitor == nil {
            // Use local monitor to intercept keys before TextField consumes them
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                return self.handleKeyEvent(event) ? nil : event
            }
        } else if window == nil, let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
    
    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // Handle Cmd+1-9 (check if command is the only modifier)
        if modifiers.contains(.command) && !modifiers.contains(.shift) && !modifiers.contains(.option) && !modifiers.contains(.control) {
            if let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars),
               digit >= 1 && digit <= 9 {
                onCommandNumber(digit)
                return true
            }
        }
        
        // Handle arrow keys and other keys (only when no modifiers except function/numericPad)
        let baseModifiers = modifiers.subtracting([.function, .numericPad])
        
        switch event.keyCode {
        case 126: // Up arrow
            if baseModifiers.isEmpty {
                onArrowUp()
                return true
            }
        case 125: // Down arrow
            if baseModifiers.isEmpty {
                onArrowDown()
                return true
            }
        case 36: // Return
            if baseModifiers.isEmpty {
                onReturn()
                return true
            }
        case 53: // Escape
            onEscape()
            return true
        default:
            break
        }
        
        return false
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

// MARK: - Command Row

private struct CommandRow: View {
    let command: Command
    let index: Int
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Command icon
            Image(systemName: command.icon)
                .font(.title3)
                .foregroundStyle(command.isDestructive ? .red : .orange)
                .frame(width: 28)
            
            // Command info
            VStack(alignment: .leading, spacing: 2) {
                Text("!\(command.trigger)")
                    .font(.body.monospaced())
                    .fontWeight(.medium)
                
                HStack(spacing: 6) {
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Category badge
            Text(command.category.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            
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
                .fill(isSelected ? Color.orange.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
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
