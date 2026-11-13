import Foundation

/// Decides whether a locally captured entry may be uploaded to iCloud.
public enum CloudSyncPolicy {
    /// Secrets and financial data. The same set semantic search and Jev keep
    /// on the device unless the user opts in.
    public static var sensitiveCategories: Set<ContentType> { JevEligibility.sensitiveCategories }

    /// Whether the entry is, or contains, a detected secret.
    public static func containsSensitiveContent(_ entry: ClipboardEntry) -> Bool {
        sensitiveCategories.contains(entry.contentType)
            || sensitiveCategories.contains { entry.contentTypeMask.contains($0) }
    }

    /// Marks a detected secret local-only unless the user chose to sync secrets.
    /// Never re-enables an entry that is already local-only.
    public static func applying(to entry: ClipboardEntry, syncSensitiveContent: Bool) -> ClipboardEntry {
        guard !syncSensitiveContent, containsSensitiveContent(entry) else { return entry }
        var entry = entry
        entry.cloudSyncAllowed = false
        return entry
    }
}
