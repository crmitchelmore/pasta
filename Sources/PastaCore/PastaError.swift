import Foundation
import os.log

/// Central error type for Pasta app with user-friendly messages
public enum PastaError: LocalizedError {
    case databaseCorrupted(underlying: Error)
    case databaseInitializationFailed(underlying: Error)
    case diskFull(path: String, underlying: Error)
    case imageSaveFailed(underlying: Error)
    case clipboardAccessDenied
    case hotkeyConflict(key: String)
    case storageUnavailable(path: String)
    case unknown(underlying: Error)
    
    public var errorDescription: String? {
        switch self {
        case .databaseCorrupted:
            return "Database Error"
        case .databaseInitializationFailed:
            return "Database Initialization Failed"
        case .diskFull:
            return "Disk Full"
        case .imageSaveFailed:
            return "Image Save Failed"
        case .clipboardAccessDenied:
            return "Clipboard Access Denied"
        case .hotkeyConflict:
            return "Hotkey Conflict"
        case .storageUnavailable:
            return "Storage Unavailable"
        case .unknown:
            return "Unexpected Error"
        }
    }
    
    public var failureReason: String? {
        switch self {
        case .databaseCorrupted:
            return "The clipboard history database is corrupted and cannot be read."
        case .databaseInitializationFailed:
            return "Failed to initialize the clipboard history database."
        case .diskFull(let path, _):
            return "Not enough disk space to save image at \(path)."
        case .imageSaveFailed:
            return "Could not save clipboard image to disk."
        case .clipboardAccessDenied:
            return "Pasta does not have permission to access the clipboard."
        case .hotkeyConflict(let key):
            return "The hotkey '\(key)' is already in use by another application."
        case .storageUnavailable(let path):
            return "Cannot access storage directory at \(path)."
        case .unknown(let error):
            return error.localizedDescription
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .databaseCorrupted:
            return "Pasta will use a temporary in-memory database. Your history will not be saved. Restart the app to attempt recovery, or delete ~/Library/Application Support/Pasta/pasta.sqlite to reset."
        case .databaseInitializationFailed:
            return "Check disk space and permissions for ~/Library/Application Support/Pasta/. Pasta will use temporary storage."
        case .diskFull:
            return "Free up disk space and try again. The clipboard entry was saved but without the image."
        case .imageSaveFailed:
            return "Check disk space and permissions for ~/Library/Application Support/Pasta/Images/."
        case .clipboardAccessDenied:
            return "Grant Accessibility permissions in System Settings > Privacy & Security > Accessibility."
        case .hotkeyConflict:
            return "Choose a different hotkey in Pasta settings."
        case .storageUnavailable:
            return "Check permissions for the application support directory."
        case .unknown:
            return "Please try restarting the app. If the problem persists, check system logs."
        }
    }
}

/// A logger wrapper that logs to both os.log and stdout
public struct ConsoleLogger {
    private let osLogger: Logger
    private let category: String
    
    init(subsystem: String, category: String) {
        self.osLogger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }
    
    private func stdout(_ level: String, _ message: String) {
        let timestamp = PastaLogger.dateFormatter.string(from: Date())
        print("[\(timestamp)] [\(level.padding(toLength: 5, withPad: " ", startingAt: 0))] [\(category)] \(message)")
    }
    
    public func debug(_ message: String) {
        osLogger.debug("\(message)")
        stdout("DEBUG", message)
    }
    
    public func info(_ message: String) {
        osLogger.info("\(message)")
        stdout("INFO", message)
    }
    
    public func warning(_ message: String) {
        osLogger.warning("\(message)")
        stdout("WARN", message)
    }
    
    public func error(_ message: String) {
        osLogger.error("\(message)")
        stdout("ERROR", message)
    }
}

/// Centralized logging for Pasta
public struct PastaLogger {
    private static let subsystem = "com.pasta.clipboard"
    
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    
    public static let app = ConsoleLogger(subsystem: subsystem, category: "app")
    public static let database = ConsoleLogger(subsystem: subsystem, category: "database")
    public static let storage = ConsoleLogger(subsystem: subsystem, category: "storage")
    public static let clipboard = ConsoleLogger(subsystem: subsystem, category: "clipboard")
    public static let hotkey = ConsoleLogger(subsystem: subsystem, category: "hotkey")
    public static let ui = ConsoleLogger(subsystem: subsystem, category: "ui")
    public static let search = ConsoleLogger(subsystem: subsystem, category: "search")
    
    /// Log an error with context
    public static func logError(_ error: Error, logger: ConsoleLogger, context: String) {
        if let pastaError = error as? PastaError {
            logger.error("\(context): \(pastaError.errorDescription ?? "Unknown") - \(pastaError.failureReason ?? "")")
        } else {
            logger.error("\(context): \(error.localizedDescription)")
        }
    }
}
