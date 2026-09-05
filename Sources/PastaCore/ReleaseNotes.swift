import Foundation

/// Offline release history. A build-specific entry takes precedence over a
/// version entry; notes for another build are never passed off as installed.
public struct ReleaseNoteEntry: Codable, Identifiable, Equatable, Sendable {
    public let version: String
    public let build: String?
    public let date: String
    public let summary: String
    public let changes: [String]
    public let source: String

    public var id: String { version + ":" + (build ?? "version") }
    public var title: String {
        build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }
}

public struct ReleaseNotesCatalog: Codable, Equatable, Sendable {
    public let entries: [ReleaseNoteEntry]

    public static let bundled: ReleaseNotesCatalog = {
        guard let url = Bundle.module.url(forResource: "IOSReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self(entries: []) }
        return catalog
    }()

    public init(entries: [ReleaseNoteEntry]) { self.entries = entries }

    public func entry(version: String, build: String) -> ReleaseNoteEntry? {
        entries.first { $0.version == version && $0.build == build }
            ?? entries.first { $0.version == version && $0.build == nil }
    }

    public func history(version: String, build: String) -> [ReleaseNoteEntry] {
        let selected = entry(version: version, build: build)?.id
        return entries.filter {
            $0.id != selected && $0.version.compare(version, options: .numeric) != .orderedDescending
                && ($0.version != version || $0.build == nil
                    || $0.build!.compare(build, options: .numeric) != .orderedDescending)
        }.sorted {
            if $0.version != $1.version {
                return $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }
            return ($0.build ?? "").compare($1.build ?? "", options: .numeric) == .orderedDescending
        }
    }
}

/// The old version-only key deliberately does not suppress the first display
/// after upgrading this implementation: old code marked notes seen before the
/// sheet was visible and even when it contained stale copy.
public enum ReleaseNotesPresentation {
    public static let acknowledgedKey = "pasta.ios.acknowledgedRelease"

    public static func identity(version: String, build: String) -> String {
        "\(version):\(build)"
    }

    public static func shouldPresent(onboardingCompleted: Bool, acknowledged: String?, version: String, build: String) -> Bool {
        onboardingCompleted && acknowledged != identity(version: version, build: build)
    }
}
