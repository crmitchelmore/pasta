import Foundation
import os.log

public final class ExclusionManager {
    private let userDefaults: UserDefaults
    private let key: String

    public init(userDefaults: UserDefaults = .standard, key: String = "pasta.excludedApps") {
        self.userDefaults = userDefaults
        self.key = key
    }

    public var excludedBundleIdentifiers: Set<String> {
        let raw = userDefaults.string(forKey: key) ?? ""
        return Set(
            raw
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    public func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        let excluded = excludedBundleIdentifiers.contains(bundleIdentifier)
        if excluded {
            PastaLogger.clipboard.debug("App excluded from clipboard history: \(bundleIdentifier)")
        }
        return excluded
    }
}
