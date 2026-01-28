import Foundation

/// Registry of all available commands, with search and execution capabilities.
@MainActor
public final class CommandRegistry: ObservableObject {
    public static let shared = CommandRegistry()
    
    @Published public private(set) var commands: [Command] = []
    
    /// Handlers injected by the app layer for actions that require AppKit/UI
    public var handlers = CommandHandlers()
    
    private init() {
        registerCommands()
    }
    
    /// Search commands matching the query (without the leading !)
    public func search(query: String) -> [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        
        // Empty query or just "!" shows all commands
        if trimmed.isEmpty {
            return commands
        }
        
        // Try to parse dynamic clear command first
        if let dynamicCommand = parseDynamicClear(query: trimmed) {
            // Put the dynamic match first, then other matching commands
            var results = [dynamicCommand]
            results.append(contentsOf: commands.filter { cmd in
                cmd.trigger.lowercased().contains(trimmed) && cmd.id != dynamicCommand.id
            })
            return results
        }
        
        // Filter by prefix or contains match
        let exactPrefix = commands.filter { $0.trigger.lowercased().hasPrefix(trimmed) }
        let contains = commands.filter { 
            $0.trigger.lowercased().contains(trimmed) && !$0.trigger.lowercased().hasPrefix(trimmed)
        }
        
        return exactPrefix + contains
    }
    
    /// Execute a command
    public func execute(_ command: Command) async -> CommandResult {
        await command.action()
    }
    
    // MARK: - Command Registration
    
    private func registerCommands() {
        var cmds: [Command] = []
        
        // MARK: Clear Commands
        cmds.append(Command(
            id: "clear-10-mins",
            trigger: "clear 10 mins",
            description: "Clear entries from last 10 minutes",
            icon: "trash",
            category: .clear,
            action: { [weak self] in
                await self?.executeClear(minutes: 10) ?? .error("Registry unavailable")
            }
        ))
        
        cmds.append(Command(
            id: "clear-1-hour",
            trigger: "clear 1 hour",
            description: "Clear entries from last hour",
            icon: "trash",
            category: .clear,
            action: { [weak self] in
                await self?.executeClear(minutes: 60) ?? .error("Registry unavailable")
            }
        ))
        
        cmds.append(Command(
            id: "clear-1-day",
            trigger: "clear 1 day",
            description: "Clear entries from last 24 hours",
            icon: "trash",
            category: .clear,
            action: { [weak self] in
                await self?.executeClear(minutes: 1440) ?? .error("Registry unavailable")
            }
        ))
        
        cmds.append(Command(
            id: "clear-all",
            trigger: "clear all",
            description: "Clear all clipboard history",
            icon: "trash.fill",
            category: .clear,
            isDestructive: true,
            action: { [weak self] in
                guard let self else { return .error("Registry unavailable") }
                return .needsConfirmation("This will delete ALL clipboard history. Are you sure?") {
                    await self.executeClearAll()
                }
            }
        ))
        
        // MARK: Monitoring Commands
        cmds.append(Command(
            id: "pause",
            trigger: "pause",
            description: "Pause clipboard monitoring",
            icon: "pause.circle",
            category: .monitoring,
            action: {
                UserDefaults.standard.set(true, forKey: "pasta.pauseMonitoring")
                return .success("Clipboard monitoring paused")
            }
        ))
        
        cmds.append(Command(
            id: "resume",
            trigger: "resume",
            description: "Resume clipboard monitoring",
            icon: "play.circle",
            category: .monitoring,
            action: {
                UserDefaults.standard.set(false, forKey: "pasta.pauseMonitoring")
                return .success("Clipboard monitoring resumed")
            }
        ))
        
        // MARK: Settings Commands
        cmds.append(contentsOf: createToggleCommands())
        cmds.append(contentsOf: createThemeCommands())
        
        // MARK: Navigation Commands
        cmds.append(Command(
            id: "settings",
            trigger: "settings",
            description: "Open settings window",
            icon: "gearshape",
            category: .navigation,
            action: { [weak self] in
                self?.handlers.openSettings?()
                return .dismissed
            }
        ))
        
        cmds.append(Command(
            id: "updates",
            trigger: "updates",
            description: "Check for updates",
            icon: "arrow.down.circle",
            category: .navigation,
            action: { [weak self] in
                self?.handlers.checkForUpdates?()
                return .success("Checking for updates...")
            }
        ))
        
        cmds.append(Command(
            id: "release-notes",
            trigger: "release notes",
            description: "Open release notes",
            icon: "doc.text",
            category: .navigation,
            action: { [weak self] in
                self?.handlers.openReleaseNotes?()
                return .dismissed
            }
        ))
        
        cmds.append(Command(
            id: "quit",
            trigger: "quit",
            description: "Quit Pasta",
            icon: "power",
            category: .navigation,
            action: { [weak self] in
                self?.handlers.quitApp?()
                return .dismissed
            }
        ))
        
        // MARK: Filter Commands
        cmds.append(contentsOf: createFilterCommands())
        
        // MARK: Utility Commands
        cmds.append(Command(
            id: "help",
            trigger: "help",
            description: "Show all available commands",
            icon: "questionmark.circle",
            category: .utility,
            action: {
                // Just return success - the UI will show all commands
                return .success("Showing all commands")
            }
        ))
        
        self.commands = cmds
    }
    
    private func createToggleCommands() -> [Command] {
        let toggles: [(id: String, key: String, name: String, icon: String)] = [
            ("sounds", "pasta.playSounds", "sounds", "speaker.wave.2"),
            ("notifications", "pasta.showNotifications", "notifications", "bell"),
            ("images", "pasta.storeImages", "image storage", "photo"),
            ("dedupe", "pasta.deduplicateEntries", "deduplication", "doc.on.doc"),
            ("extract", "pasta.extractContent", "content extraction", "text.magnifyingglass"),
            ("skip-api-keys", "pasta.skipAPIKeys", "API key filtering", "key"),
        ]
        
        var commands: [Command] = []
        for toggle in toggles {
            commands.append(Command(
                id: "\(toggle.id)-on",
                trigger: "\(toggle.id) on",
                description: "Enable \(toggle.name)",
                icon: toggle.icon,
                category: .settings,
                action: {
                    UserDefaults.standard.set(true, forKey: toggle.key)
                    return .success("\(toggle.name.capitalized) enabled")
                }
            ))
            commands.append(Command(
                id: "\(toggle.id)-off",
                trigger: "\(toggle.id) off",
                description: "Disable \(toggle.name)",
                icon: toggle.icon,
                category: .settings,
                action: {
                    UserDefaults.standard.set(false, forKey: toggle.key)
                    return .success("\(toggle.name.capitalized) disabled")
                }
            ))
        }
        return commands
    }
    
    private func createThemeCommands() -> [Command] {
        let themes = [("light", "Light"), ("dark", "Dark"), ("system", "System")]
        return themes.map { theme in
            Command(
                id: "theme-\(theme.0)",
                trigger: "theme \(theme.0)",
                description: "Set appearance to \(theme.1)",
                icon: theme.0 == "dark" ? "moon" : (theme.0 == "light" ? "sun.max" : "circle.lefthalf.filled"),
                category: .settings,
                action: {
                    UserDefaults.standard.set(theme.0, forKey: "pasta.appearance")
                    return .success("Theme set to \(theme.1)")
                }
            )
        }
    }
    
    private func createFilterCommands() -> [Command] {
        let filters: [(trigger: String, type: ContentType?, icon: String, desc: String)] = [
            ("urls", .url, "link", "Show only URLs"),
            ("emails", .email, "envelope", "Show only emails"),
            ("images", .image, "photo", "Show only images"),
            ("text", .text, "doc.text", "Show only plain text"),
            ("code", .code, "chevron.left.forwardslash.chevron.right", "Show only code snippets"),
            ("paths", .filePath, "folder", "Show only file paths"),
        ]
        
        return filters.map { filter in
            Command(
                id: "filter-\(filter.trigger)",
                trigger: filter.trigger,
                description: filter.desc,
                icon: filter.icon,
                category: .filter,
                action: {
                    return .openMainWindow(contentType: filter.type)
                }
            )
        }
    }
    
    // MARK: - Dynamic Command Parsing
    
    /// Parse dynamic clear commands like "clear 5 mins", "clear 2 hours", "clear 3 days"
    private func parseDynamicClear(query: String) -> Command? {
        // Pattern: clear <number> <unit>
        let pattern = "^clear\\s+(\\d+)\\s*(mins?|minutes?|m|hours?|hr?|days?|d)$"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              match.numberOfRanges >= 3,
              let numberRange = Range(match.range(at: 1), in: query),
              let unitRange = Range(match.range(at: 2), in: query) else {
            return nil
        }
        
        let number = Int(query[numberRange]) ?? 0
        let unit = String(query[unitRange]).lowercased()
        
        let minutes: Int
        let unitDisplay: String
        
        switch unit {
        case "m", "min", "mins", "minute", "minutes":
            minutes = number
            unitDisplay = number == 1 ? "minute" : "minutes"
        case "h", "hr", "hour", "hours":
            minutes = number * 60
            unitDisplay = number == 1 ? "hour" : "hours"
        case "d", "day", "days":
            minutes = number * 1440
            unitDisplay = number == 1 ? "day" : "days"
        default:
            return nil
        }
        
        guard minutes > 0 else { return nil }
        
        return Command(
            id: "clear-\(minutes)-mins-dynamic",
            trigger: "clear \(number) \(unitDisplay)",
            description: "Clear entries from last \(number) \(unitDisplay)",
            icon: "trash",
            category: .clear,
            action: { [weak self] in
                await self?.executeClear(minutes: minutes) ?? .error("Registry unavailable")
            }
        )
    }
    
    // MARK: - Command Execution
    
    private func executeClear(minutes: Int) async -> CommandResult {
        guard let deleteRecent = handlers.deleteRecent else {
            return .error("Delete handler not configured")
        }
        
        do {
            let count = try deleteRecent(minutes)
            let timeDesc = formatTimeDescription(minutes: minutes)
            return .success("Cleared \(count) \(count == 1 ? "entry" : "entries") from last \(timeDesc)")
        } catch {
            return .error("Failed to clear: \(error.localizedDescription)")
        }
    }
    
    private func executeClearAll() async -> CommandResult {
        guard let deleteAll = handlers.deleteAll else {
            return .error("Delete handler not configured")
        }
        
        do {
            let count = try deleteAll()
            return .success("Cleared all \(count) entries")
        } catch {
            return .error("Failed to clear: \(error.localizedDescription)")
        }
    }
    
    private func formatTimeDescription(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        } else if minutes < 1440 {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        } else {
            let days = minutes / 1440
            return "\(days) \(days == 1 ? "day" : "days")"
        }
    }
}

/// Handlers for commands that need app-layer implementations
public struct CommandHandlers: Sendable {
    public var deleteRecent: (@Sendable @MainActor (Int) throws -> Int)?
    public var deleteAll: (@Sendable @MainActor () throws -> Int)?
    public var openSettings: (@Sendable @MainActor () -> Void)?
    public var checkForUpdates: (@Sendable @MainActor () -> Void)?
    public var openReleaseNotes: (@Sendable @MainActor () -> Void)?
    public var quitApp: (@Sendable @MainActor () -> Void)?
    public var openMainWindow: (@Sendable @MainActor (ContentType?) -> Void)?
    
    public init() {}
}
