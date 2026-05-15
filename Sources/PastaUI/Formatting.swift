import Foundation

// MARK: - Relative Date Formatter (cached, abbreviated style)

private let sharedRelativeDateTimeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

extension Date {
    /// Canonical relative-date string, e.g. "3m ago", "1h ago".
    /// Uses a shared cached `RelativeDateTimeFormatter` with abbreviated style.
    var relativeFormatted: String {
        sharedRelativeDateTimeFormatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - App display name from bundle identifier

extension String {
    /// Extracts a readable app name from a bundle identifier
    /// (e.g. "com.apple.Safari" -> "Safari"). Returns the input unchanged if it
    /// has no dots.
    var appDisplayName: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Unknown" {
            return "Unknown"
        }
        if trimmed == "Continuity" {
            return "Continuity"
        }
        let parts = trimmed.split(separator: ".")
        if let last = parts.last {
            return String(last).capitalized
        }
        return trimmed
    }
}
