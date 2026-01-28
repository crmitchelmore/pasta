import Foundation

/// A command that can be executed from command mode (queries starting with !)
public struct Command: Identifiable, Sendable {
    public let id: String
    public let trigger: String
    public let description: String
    public let icon: String
    public let category: CommandCategory
    public let isDestructive: Bool
    
    /// The action to execute. Returns a result message (e.g., "Cleared 47 entries")
    public let action: @Sendable @MainActor () async -> CommandResult
    
    public init(
        id: String,
        trigger: String,
        description: String,
        icon: String,
        category: CommandCategory,
        isDestructive: Bool = false,
        action: @escaping @Sendable @MainActor () async -> CommandResult
    ) {
        self.id = id
        self.trigger = trigger
        self.description = description
        self.icon = icon
        self.category = category
        self.isDestructive = isDestructive
        self.action = action
    }
}

public enum CommandCategory: String, CaseIterable, Sendable {
    case clear = "Clear"
    case monitoring = "Monitoring"
    case settings = "Settings"
    case navigation = "Navigation"
    case filter = "Filter"
    case utility = "Utility"
    
    public var icon: String {
        switch self {
        case .clear: return "trash"
        case .monitoring: return "pause.circle"
        case .settings: return "gearshape"
        case .navigation: return "arrow.right.circle"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .utility: return "wrench"
        }
    }
}

public enum CommandResult: Sendable {
    case success(String)
    case needsConfirmation(String, confirmAction: @Sendable @MainActor () async -> CommandResult)
    case error(String)
    case openMainWindow(contentType: ContentType?)
    case dismissed
    
    public var message: String? {
        switch self {
        case .success(let msg): return msg
        case .error(let msg): return msg
        case .needsConfirmation(let msg, _): return msg
        case .openMainWindow, .dismissed: return nil
        }
    }
}
