#if os(macOS)
import Foundation

/// Result of an import operation
public struct ImportResult {
    public let imported: Int
    public let skipped: Int
    public let failed: Int
    public let errors: [String]

    public var summary: String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) imported") }
        if skipped > 0 { parts.append("\(skipped) duplicates skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "No items found" : parts.joined(separator: ", ")
    }
}

/// Progress callback for import operations
public struct ImportProgress: Sendable {
    public let current: Int
    public let total: Int
    public let imported: Int
    public let skipped: Int

    public var fraction: Double {
        total > 0 ? Double(current) / Double(total) : 0
    }
}

/// Result of an export operation
public struct ExportResult {
    public let exported: Int
    public let fileURL: URL
}

// MARK: - Import Errors

public enum ImportError: LocalizedError {
    case databaseNotFound(app: String)
    case unrecognizedSchema(app: String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let app):
            return "Could not find \(app) database"
        case .unrecognizedSchema(let app):
            return "Unrecognized \(app) database format"
        }
    }
}
#endif
