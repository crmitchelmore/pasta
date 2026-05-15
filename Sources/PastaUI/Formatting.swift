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
        SourceAppDisplay.displayName(for: self)
    }
}

public enum SourceAppDisplay {
    public static func displayName(for sourceApp: String?) -> String {
        guard let sourceApp else { return "Unknown" }
        let trimmed = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Unknown" {
            return "Unknown"
        }
        if trimmed == "Continuity" {
            return "Continuity"
        }

        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count > 1 else {
            return trimmed
        }

        let candidate = parts.reversed().first { part in
            part.rangeOfCharacter(from: .letters) != nil
        } ?? parts.last ?? trimmed
        return humanize(candidate)
    }

    public static func groupingKey(for sourceApp: String?) -> String {
        let displayName = displayName(for: sourceApp).lowercased()
        let scalars = displayName.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let key = String(String.UnicodeScalarView(scalars))
        return key.isEmpty ? "unknown" : key
    }

    public static func countKey(for sourceApp: String?, replacing currentKey: String? = nil) -> String {
        let candidate = normalizedIdentifier(sourceApp)
        guard let currentKey else { return candidate }

        if isResolvableIdentifier(candidate), !isResolvableIdentifier(currentKey) {
            return candidate
        }
        return currentKey
    }

    public static func groupedCounts(_ rawCounts: [String: Int]) -> [String: Int] {
        var grouped: [String: (representative: String, count: Int)] = [:]

        for (sourceApp, count) in rawCounts {
            let group = groupingKey(for: sourceApp)
            let current = grouped[group]
            let representative = countKey(for: sourceApp, replacing: current?.representative)
            grouped[group] = (representative, (current?.count ?? 0) + count)
        }

        var out: [String: Int] = [:]
        out.reserveCapacity(grouped.count)
        for (_, value) in grouped {
            out[value.representative] = value.count
        }
        return out
    }

    public static func matches(_ sourceApp: String?, filter: String) -> Bool {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty else { return true }
        guard let sourceApp else { return false }

        return sourceApp.localizedCaseInsensitiveContains(trimmedFilter) ||
            displayName(for: sourceApp).localizedCaseInsensitiveContains(trimmedFilter) ||
            groupingKey(for: sourceApp) == groupingKey(for: trimmedFilter)
    }

    private static func normalizedIdentifier(_ sourceApp: String?) -> String {
        guard let sourceApp else { return "Unknown" }
        let trimmed = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private static func isResolvableIdentifier(_ sourceApp: String) -> Bool {
        sourceApp.contains(".") && sourceApp != "Continuity" && sourceApp != "Unknown"
    }

    private static func humanize(_ value: String) -> String {
        let spaced = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spaced.isEmpty else { return "Unknown" }
        if let preferred = preferredDisplayNames[groupingKey(for: spaced)] {
            return preferred
        }
        return spaced.capitalized
    }

    private static let preferredDisplayNames: [String: String] = [
        "googlechrome": "Google Chrome",
        "microsoftteams": "Microsoft Teams",
        "sublimetext": "Sublime Text",
        "whatsapp": "WhatsApp"
    ]
}
