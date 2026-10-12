import Foundation

public struct DecisionClassifierDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var contentType: ContentType

    public init(id: UUID = UUID(), name: String, description: String, contentType: ContentType = .text) {
        self.id = id
        self.name = name
        self.description = description
        self.contentType = contentType
    }

    public var choiceID: String { "custom_\(id.uuidString.lowercased())" }
}

public struct DecisionClassificationRules: Codable, Equatable, Sendable {
    public static let defaultsKey = "pasta.decisionClassification.rules.v1"
    public static let maxCustomClassifiers = 32
    public static let `default` = DecisionClassificationRules()
    public static var customContentTypes: [ContentType] {
        JevSystemOneRequest.options.map(\.category).filter { $0 != .unknown && $0 != .filePath }
    }

    public var descriptions: [String: String]
    public var customClassifiers: [DecisionClassifierDefinition]

    public init(descriptions: [String: String] = [:], customClassifiers: [DecisionClassifierDefinition] = []) {
        self.descriptions = descriptions
        self.customClassifiers = customClassifiers
    }

    public func validated() throws -> Self {
        var result = self
        let builtInNames = Set(JevSystemOneRequest.options.map { $0.category.rawValue })
        let customTypes = Set(Self.customContentTypes)
        guard Set(descriptions.keys).isSubset(of: builtInNames),
              customClassifiers.count <= Self.maxCustomClassifiers else {
            throw DecisionRulesError.invalid("Use supported types and at most \(Self.maxCustomClassifiers) custom classifiers.")
        }
        for (key, value) in descriptions {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 1_000 else {
                throw DecisionRulesError.invalid("Each type description must contain 1-1,000 characters.")
            }
            result.descriptions[key] = trimmed
        }
        var names = Set<String>()
        var ids = Set<UUID>()
        for index in result.customClassifiers.indices {
            result.customClassifiers[index].name = customClassifiers[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.customClassifiers[index].description = customClassifiers[index].description.trimmingCharacters(in: .whitespacesAndNewlines)
            let classifier = result.customClassifiers[index]
            guard !classifier.name.isEmpty, classifier.name.count <= 80,
                  !classifier.description.isEmpty, classifier.description.count <= 1_000,
                  customTypes.contains(classifier.contentType),
                  names.insert(classifier.name.lowercased()).inserted, ids.insert(classifier.id).inserted else {
                throw DecisionRulesError.invalid("Custom classifiers need unique names (up to 80 characters), a description (up to 1,000 characters), and a supported text type other than Unknown or File Path.")
            }
        }
        return result
    }

    public var choices: [(id: String, description: String, category: ContentType)] {
        let custom = customClassifiers.map { (id: $0.choiceID, description: "\($0.name): \($0.description)", category: $0.contentType) }
        let builtIn = JevSystemOneRequest.options.map {
            (id: $0.category.rawValue, description: descriptions[$0.category.rawValue] ?? $0.description, category: $0.category)
        }
        return custom + builtIn
    }

    public func customClassifier(for choice: String) -> DecisionClassifierDefinition? {
        customClassifiers.first { $0.choiceID == choice }
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey) else { return .default }
        do {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.app, context: "Decision classifier rules could not be loaded; remote providers disabled")
            for provider in RemoteClassificationProvider.allCases {
                JevConfiguration.invalidateValidation(provider: provider, defaults: defaults)
            }
            return .default
        }
    }

    public func save(defaults: UserDefaults = .standard) throws {
        let rules = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rules)
        guard defaults.data(forKey: Self.defaultsKey) != data,
              defaults.data(forKey: Self.defaultsKey) != nil || rules != .default else { return }
        for provider in RemoteClassificationProvider.allCases {
            JevConfiguration.invalidateValidation(provider: provider, defaults: defaults)
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return ClipboardEntry.sha256Hex(try encoder.encode(validated()).base64EncodedString())
        }
    }
}

public enum DecisionRulesError: LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

public enum DecisionModelSelection {
    public static let defaultsKey = "pasta.decisionClassification.preferredProvider"
    public static let setupOfferedKey = "pasta.decisionClassification.setupOffered.v1"

    public static func provider(defaults: UserDefaults = .standard) -> RemoteClassificationProvider {
        RemoteClassificationProvider(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .jev
    }

    public static func select(_ provider: RemoteClassificationProvider, defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: defaultsKey)
    }

    public static func configuration(defaults: UserDefaults = .standard) -> JevConfiguration {
        JevConfiguration.load(provider: provider(defaults: defaults), defaults: defaults)
    }

    public static func shouldOfferSetup(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: setupOfferedKey)
            && !RemoteClassificationProvider.allCases.contains { JevConfiguration.load(provider: $0, defaults: defaults).isEnabled }
    }
}
