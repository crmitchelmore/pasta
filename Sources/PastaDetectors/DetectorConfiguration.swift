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

public extension BuiltInDetectorKind {
    func builtInPatterns(for strictness: DetectorStrictness) -> [String] {
        switch self {
        case .phoneNumber:
            return PhoneNumberDetector.builtInPatterns(for: strictness)
        case .email:
            return Self.emailPatterns(for: strictness)
        case .url:
            return Self.urlPatterns(for: strictness)
        case .ipAddress:
            return Self.ipAddressPatterns(for: strictness)
        case .uuid:
            return Self.uuidPatterns(for: strictness)
        case .hash:
            return Self.hashPatterns(for: strictness)
        case .jwt:
            return Self.jwtPatterns(for: strictness)
        case .apiKey:
            return Self.apiKeyPatterns(for: strictness)
        case .filePath:
            return Self.filePathPatterns(for: strictness)
        case .envVar:
            return Self.envVarPatterns(for: strictness)
        case .shellCommand:
            return Self.shellCommandPatterns(for: strictness)
        }
    }

    private static func emailPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict, .medium:
            return [
                #"(?i)(?<![A-Z0-9._%+\-])([A-Z0-9](?:[A-Z0-9._%+\-]{0,62}[A-Z0-9])?)@([A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?)+)(?![A-Z0-9_%+\-])"#
            ]
        case .lax:
            return [
                #"(?i)(?<![A-Z0-9._%+\-])([A-Z0-9](?:[A-Z0-9._%+\-]{0,62}[A-Z0-9])?)@([A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?)*)(?![A-Z0-9_%+\-])"#
            ]
        }
    }

    private static func urlPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return [
                #"(?i)\b(https://[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+(?:/[^\s<>'"]*)?)"#
            ]
        case .medium:
            return [
                #"(?i)\b((?:https?|ftp)://[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+(?:/[^\s<>'"]*)?)"#
            ]
        case .lax:
            return [
                #"(?i)\b((?:https?|ftp)://[A-Z0-9._:-]+(?:/[^\s<>'"]*)?)"#
            ]
        }
    }

    private static func ipAddressPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict, .medium, .lax:
            return [
                #"(?<![0-9])((?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})(?![0-9])"#,
                #"(?i)(?<![0-9a-f])((?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,5}(?::[0-9a-f]{1,4}){1,2}|(?:[0-9a-f]{1,4}:){1,4}(?::[0-9a-f]{1,4}){1,3}|(?:[0-9a-f]{1,4}:){1,3}(?::[0-9a-f]{1,4}){1,4}|(?:[0-9a-f]{1,4}:){1,2}(?::[0-9a-f]{1,4}){1,5}|[0-9a-f]{1,4}:(?::[0-9a-f]{1,4}){1,6}|:(?::[0-9a-f]{1,4}){1,7}|fe80:(?::[0-9a-f]{0,4}){0,4}%[0-9a-z]+|::(?:ffff(?::0{1,4}){0,1}:){0,1}(?:\d{1,3}\.){3}\d{1,3}|(?:[0-9a-f]{1,4}:){1,4}:(?:\d{1,3}\.){3}\d{1,3})(?![0-9a-f])"#
            ]
        }
    }

    private static func uuidPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict, .medium, .lax:
            return [
                #"(?i)(?<![0-9a-f])([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f])"#
            ]
        }
    }

    private static func hashPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return [
                #"(?i)(?<![0-9a-f])([0-9a-f]{56}|[0-9a-f]{64}|[0-9a-f]{96}|[0-9a-f]{128})(?![0-9a-f])"#,
                #"(?<![A-Za-z0-9+/=])([A-Za-z0-9+/]{86}={0,2}|[A-Za-z0-9+/]{128}={0,2}|[A-Za-z0-9+/]{171}={0,2})(?![A-Za-z0-9+/=])"#
            ]
        case .medium:
            return [
                #"(?i)(?<![0-9a-f])([0-9a-f]{32}|[0-9a-f]{40}|[0-9a-f]{56}|[0-9a-f]{64}|[0-9a-f]{96}|[0-9a-f]{128})(?![0-9a-f])"#,
                #"(?<![A-Za-z0-9+/=])([A-Za-z0-9+/]{43}={0,2}|[A-Za-z0-9+/]{86}={0,2}|[A-Za-z0-9+/]{128}={0,2}|[A-Za-z0-9+/]{171}={0,2})(?![A-Za-z0-9+/=])"#
            ]
        case .lax:
            return [
                #"(?i)(?<![0-9a-f])([0-9a-f]{24,128})(?![0-9a-f])"#,
                #"(?<![A-Za-z0-9+/=])([A-Za-z0-9+/]{32,}={0,2})(?![A-Za-z0-9+/=])"#
            ]
        }
    }

    private static func jwtPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict, .medium, .lax:
            return [
                #"(?<![A-Za-z0-9_\-])([A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)(?![A-Za-z0-9_\-])"#
            ]
        }
    }

    private static func apiKeyPatterns(for strictness: DetectorStrictness) -> [String] {
        let core: [String] = [
            #"sk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20}"#,
            #"sk-proj-[a-zA-Z0-9\-_]{80,180}"#,
            #"sk-[a-zA-Z0-9]{48}"#,
            #"sk-ant-api03-[a-zA-Z0-9\-_]{93}"#,
            #"sk-ant-[a-zA-Z0-9\-_]{40,100}"#,
            #"AIza[0-9A-Za-z\-_]{35}"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"(?<![A-Za-z0-9/+])[A-Za-z0-9/+=]{40}(?![A-Za-z0-9/+=])"#,
            #"ghp_[a-zA-Z0-9]{36}"#,
            #"github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}"#,
            #"gho_[a-zA-Z0-9]{36}"#,
            #"ghu_[a-zA-Z0-9]{36}"#,
            #"ghr_[a-zA-Z0-9]{36}"#,
            #"sk_live_[a-zA-Z0-9]{24,}"#,
            #"sk_test_[a-zA-Z0-9]{24,}"#,
            #"pk_live_[a-zA-Z0-9]{24,}"#,
            #"rk_live_[a-zA-Z0-9]{24,}"#,
            #"xoxb-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}"#,
            #"xoxp-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}"#,
            #"xapp-[0-9]-[A-Z0-9]+-[0-9]+-[a-zA-Z0-9]+"#,
            #"https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[a-zA-Z0-9]+"#,
            #"SK[a-f0-9]{32}"#,
            #"AC[a-f0-9]{32}"#,
            #"SG\.[a-zA-Z0-9\-_]{22}\.[a-zA-Z0-9\-_]{43}"#,
            #"key-[a-f0-9]{32}"#,
            #"npm_[a-zA-Z0-9]{36}"#,
            #"pypi-[a-zA-Z0-9\-_]{100,}"#,
            #"dop_v1_[a-f0-9]{64}"#,
            #"doo_v1_[a-f0-9]{64}"#,
            #"[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27}"#,
            #"https://discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#,
            #"AAAA[A-Za-z0-9_-]{7}:[A-Za-z0-9_-]{140}"#,
            #"lin_api_[a-zA-Z0-9]{40}"#,
            #"sbp_[a-f0-9]{40}"#,
            #"r8_[a-zA-Z0-9]{37}"#,
            #"hf_[a-zA-Z0-9]{34}"#,
            #"pk\.[a-zA-Z0-9]{60,}"#,
            #"sk\.[a-zA-Z0-9]{60,}"#,
            #"pscale_tkn_[a-zA-Z0-9_]+"#,
        ]
        let bearer: [String] = [
            #"Bearer\s+[a-zA-Z0-9\-_\.]{20,}"#
        ]
        let generic: [String] = [
            #"(?i)api[_-]?key['":\s=]+['"]?([a-zA-Z0-9\-_]{20,})['"]?"#,
            #"(?i)secret[_-]?key['":\s=]+['"]?([a-zA-Z0-9\-_]{20,})['"]?"#,
            #"(?i)access[_-]?token['":\s=]+['"]?([a-zA-Z0-9\-_]{20,})['"]?"#,
        ]

        switch strictness {
        case .strict:
            return core
        case .medium:
            return core + bearer
        case .lax:
            return core + bearer + generic
        }
    }

    private static func filePathPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return [
                #"(?i)(?<![A-Z0-9_])([A-Z]:\\[^\s\"'<>|]+|[A-Z]:/[^\s\"'<>|]+)"#,
                #"(?<![A-Za-z]:)(?<![A-Za-z0-9_\-])((?:~|/)(?:[^\s\"']+))"#
            ]
        case .medium:
            return [
                #"(?i)(?<![A-Z0-9_])([A-Z]:\\[^\s\"'<>|]+|[A-Z]:/[^\s\"'<>|]+)"#,
                #"(?<![A-Za-z]:)(?<![A-Za-z0-9_\-])((?:~|\.{1,2})?/(?:[^\s\"']+))"#
            ]
        case .lax:
            return [
                #"(?i)(?<![A-Z0-9_])([A-Z]:\\[^\s\"'<>|]+|[A-Z]:/[^\s\"'<>|]+)"#,
                #"(?<![A-Za-z0-9_\-])((?:~|\.{1,2})?/(?:[^\s\"']+)|[A-Za-z0-9._-]+/[A-Za-z0-9._/\-]+)"#
            ]
        }
    }

    private static func envVarPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return [
                #"(?m)^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.+)\s*$"#
            ]
        case .medium:
            return [
                #"(?m)^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)\s*$"#
            ]
        case .lax:
            return [
                #"(?m)^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.+)\s*$"#
            ]
        }
    }

    private static func shellCommandPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return [
                #"(?m)^\s*[\$>]\s*([A-Za-z][A-Za-z0-9._/-]*(?:\s+[^;\n]+)?)\s*$"#,
                #"(?m)^\s*(?:sudo\s+)?([A-Za-z][A-Za-z0-9._/-]*(?:\s+--?[A-Za-z0-9][A-Za-z0-9._-]*)+(?:\s+[^;\n]+)?)\s*$"#
            ]
        case .medium:
            return [
                #"(?m)^\s*([A-Za-z][A-Za-z0-9._/-]*(?:\s+[^;\n]+)?)\s*$"#,
                #"(?m)^\s*([^\n]+(?:\|[^\n]+)+)\s*$"#
            ]
        case .lax:
            return [
                #"(?m)^\s*([^\n]+(?:&&|\|\||\|)[^\n]+)\s*$"#,
                #"(?m)^\s*([A-Za-z0-9._/-]+\s+[^=\n]+)\s*$"#
            ]
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
