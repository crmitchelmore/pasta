import Foundation
import CoreFoundation

public struct ContentExtractionConfiguration: Equatable, Sendable {
    public static let defaultsKey = "pasta.maximumExtractedItems"
    public static let defaultMaximum = 100
    public static let `default` = Self(validatedMaximum: defaultMaximum)

    /// Zero saves all eligible detections within the bounded analysis window.
    public let maximumSavedItems: Int

    public enum ConfigurationError: LocalizedError {
        case invalidMaximum
        case changedDuringReparse

        public var errorDescription: String? {
            switch self {
            case .invalidMaximum: return "The extracted-item limit must be zero (all items) or a positive number."
            case .changedDuringReparse: return "Extraction settings changed. Run Reparse History again to apply the new settings."
            }
        }
    }

    public init(maximumSavedItems: Int) throws {
        guard maximumSavedItems >= 0 else { throw ConfigurationError.invalidMaximum }
        self.maximumSavedItems = maximumSavedItems
    }

    private init(validatedMaximum: Int) {
        maximumSavedItems = validatedMaximum
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let stored = defaults.object(forKey: defaultsKey) else { return .default }
        do {
            guard let number = stored as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue) else {
                throw ConfigurationError.invalidMaximum
            }
            return try Self(maximumSavedItems: number.intValue)
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.clipboard, context: "Invalid extracted-item limit; using 100")
            return .default
        }
    }

    public func limit<T>(_ items: [T]) -> [T] {
        maximumSavedItems == 0 ? items : Array(items.prefix(maximumSavedItems))
    }

    public var reparsePageSize: Int {
        maximumSavedItems == 0 ? 1 : max(1, min(500, 10_000 / maximumSavedItems))
    }
}
