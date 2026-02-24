import Foundation

public enum DetectorStrictness: String, Codable, CaseIterable, Sendable {
    case lax
    case medium
    case strict

    public var displayName: String {
        switch self {
        case .lax: return "Lax"
        case .medium: return "Medium"
        case .strict: return "Strict"
        }
    }
}

public enum DetectorStrictnessOverride: String, Codable, CaseIterable, Sendable {
    case inherit
    case lax
    case medium
    case strict

    public var displayName: String {
        switch self {
        case .inherit: return "Inherit"
        case .lax: return "Lax"
        case .medium: return "Medium"
        case .strict: return "Strict"
        }
    }

    public var resolved: DetectorStrictness? {
        switch self {
        case .inherit: return nil
        case .lax: return .lax
        case .medium: return .medium
        case .strict: return .strict
        }
    }
}

public enum BuiltInDetectorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case phoneNumber
    case email
    case url
    case ipAddress
    case uuid
    case hash
    case jwt
    case apiKey
    case filePath
    case envVar
    case shellCommand

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .phoneNumber: return "Phone Numbers"
        case .email: return "Email Addresses"
        case .url: return "URLs"
        case .ipAddress: return "IP Addresses"
        case .uuid: return "UUIDs"
        case .hash: return "Hashes"
        case .jwt: return "JWT Tokens"
        case .apiKey: return "API Keys"
        case .filePath: return "File Paths"
        case .envVar: return "Environment Variables"
        case .shellCommand: return "Shell Commands"
        }
    }
}

public struct DetectorRuleConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var strictnessOverride: DetectorStrictnessOverride
    public var useAdvancedPatterns: Bool
    public var advancedPatterns: [String]

    public init(
        isEnabled: Bool = true,
        strictnessOverride: DetectorStrictnessOverride = .inherit,
        useAdvancedPatterns: Bool = false,
        advancedPatterns: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.strictnessOverride = strictnessOverride
        self.useAdvancedPatterns = useAdvancedPatterns
        self.advancedPatterns = advancedPatterns
    }

    public var cleanedPatterns: [String] {
        advancedPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct CustomDetectorDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var isEnabled: Bool
    public var isCaseInsensitive: Bool
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        isEnabled: Bool = true,
        isCaseInsensitive: Bool = true,
        confidence: Double = 0.75
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.isCaseInsensitive = isCaseInsensitive
        self.confidence = confidence
    }
}

public struct DetectorConfiguration: Codable, Equatable, Sendable {
    public var globalStrictness: DetectorStrictness
    public var builtInRules: [String: DetectorRuleConfig]
    public var customDetectors: [CustomDetectorDefinition]

    public init(
        globalStrictness: DetectorStrictness = .medium,
        builtInRules: [String: DetectorRuleConfig] = [:],
        customDetectors: [CustomDetectorDefinition] = []
    ) {
        self.globalStrictness = globalStrictness
        self.builtInRules = builtInRules
        self.customDetectors = customDetectors
    }

    public static var `default`: DetectorConfiguration {
        var rules: [String: DetectorRuleConfig] = [:]
        for detector in BuiltInDetectorKind.allCases {
            rules[detector.rawValue] = DetectorRuleConfig()
        }
        return DetectorConfiguration(
            globalStrictness: .medium,
            builtInRules: rules,
            customDetectors: []
        )
    }

    public func normalized() -> DetectorConfiguration {
        var copy = self
        for detector in BuiltInDetectorKind.allCases where copy.builtInRules[detector.rawValue] == nil {
            copy.builtInRules[detector.rawValue] = DetectorRuleConfig()
        }
        copy.customDetectors = copy.customDetectors.map { detector in
            var updated = detector
            updated.name = detector.name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.pattern = detector.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.confidence = min(1.0, max(0.0, detector.confidence))
            return updated
        }.filter { !$0.name.isEmpty && !$0.pattern.isEmpty }
        return copy
    }

    public func rule(for detector: BuiltInDetectorKind) -> DetectorRuleConfig {
        builtInRules[detector.rawValue] ?? DetectorRuleConfig()
    }

    public mutating func setRule(_ rule: DetectorRuleConfig, for detector: BuiltInDetectorKind) {
        builtInRules[detector.rawValue] = rule
    }

    public func strictness(for detector: BuiltInDetectorKind) -> DetectorStrictness {
        rule(for: detector).strictnessOverride.resolved ?? globalStrictness
    }
}

public enum DetectorConfigurationStore {
    public static let defaultsKey = "pasta.detectorConfiguration.v1"

    public static func load(userDefaults: UserDefaults = .standard) -> DetectorConfiguration {
        guard let data = userDefaults.data(forKey: defaultsKey) else {
            return .default
        }
        guard let decoded = try? JSONDecoder().decode(DetectorConfiguration.self, from: data) else {
            return .default
        }
        return decoded.normalized()
    }

    public static func save(_ configuration: DetectorConfiguration, userDefaults: UserDefaults = .standard) throws {
        let normalized = configuration.normalized()
        let data = try JSONEncoder().encode(normalized)
        userDefaults.set(data, forKey: defaultsKey)
    }

    public static func reset(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: defaultsKey)
    }
}
