import Foundation

#if os(macOS)
import Security
#endif

public enum JevConfigurationError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidEndpoint
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Configure a Jev API key before running a comparison."
        case .invalidEndpoint: return "The Jev endpoint is not a valid HTTPS URL."
        case .invalidResponse: return "Jev returned an invalid classification response."
        }
    }
}

public struct JevConfiguration: Sendable, Equatable {
    public static let defaultEndpoint = "https://api.jev.ai/v1/classify"
    public var isEnabled: Bool
    public var endpoint: String
    public var model: String

    public init(
        isEnabled: Bool = false,
        endpoint: String = JevConfiguration.defaultEndpoint,
        model: String = "jev"
    ) {
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.model = model
    }

    public static func load(defaults: UserDefaults = .standard) -> JevConfiguration {
        JevConfiguration(
            isEnabled: defaults.bool(forKey: "pasta.jev.enabled"),
            endpoint: defaults.string(forKey: "pasta.jev.endpoint") ?? defaultEndpoint,
            model: defaults.string(forKey: "pasta.jev.model") ?? "jev"
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: "pasta.jev.enabled")
        defaults.set(endpoint, forKey: "pasta.jev.endpoint")
        defaults.set(model, forKey: "pasta.jev.model")
    }
}

public enum JevKeychain {
    private static let service = "com.pasta.jev.api-key"

    public static func read() throws -> String? {
#if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw JevConfigurationError.missingAPIKey
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    public static func save(_ key: String) throws {
#if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ]
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecSuccess else {
                throw JevConfigurationError.missingAPIKey
            }
        } else if status != errSecSuccess {
            throw JevConfigurationError.missingAPIKey
        }
#endif
    }

    public static func remove() throws {
#if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JevConfigurationError.missingAPIKey
        }
#endif
    }
}

public struct JevClassification: Codable, Sendable, Equatable {
    public let category: ContentType
    public let confidence: Double?
    public let explanation: String?
    public let latency: TimeInterval

    public init(category: ContentType, confidence: Double? = nil, explanation: String? = nil, latency: TimeInterval = 0) {
        self.category = category
        self.confidence = confidence
        self.explanation = explanation
        self.latency = latency
    }
}

public struct JevClassifier: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func classify(content: String, configuration: JevConfiguration, apiKey: String) async throws -> JevClassification {
        guard let url = URL(string: configuration.endpoint), url.scheme == "https" else {
            throw JevConfigurationError.invalidEndpoint
        }
        guard !apiKey.isEmpty else { throw JevConfigurationError.missingAPIKey }

        let started = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")\n        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "input": content,
            "categories": ContentType.allCases.map(\.rawValue)
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JevConfigurationError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(JevResponse.self, from: data)
        guard let category = ContentType(rawValue: decoded.category.lowercased()) else {
            return JevClassification(category: .unknown, confidence: decoded.confidence, explanation: decoded.explanation, latency: Date().timeIntervalSince(started))
        }
        return JevClassification(
            category: category,
            confidence: decoded.confidence,
            explanation: decoded.explanation,
            latency: Date().timeIntervalSince(started)
        )
    }

    private struct JevResponse: Decodable {
        let category: String
        let confidence: Double?
        let explanation: String?

        enum CodingKeys: String, CodingKey {
            case category, label, confidence, explanation, reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            category = try container.decodeIfPresent(String.self, forKey: .category)
                ?? container.decode(String.self, forKey: .label)
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
            explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
                ?? container.decodeIfPresent(String.self, forKey: .reason)
        }
    }
}

public struct JevComparisonRow: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let sourceApp: String?
    public let localCategory: ContentType
    public let jevCategory: ContentType?
    public let confidence: Double?
    public let latency: TimeInterval?
    public let error: String?

    public var isAgreement: Bool {
        guard let jevCategory else { return false }
        return localCategory == jevCategory
    }
}

public struct JevComparisonReport: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let total: Int
    public let compared: Int
    public let skipped: Int
    public let failed: Int
    public let rows: [JevComparisonRow]

    public var agreements: Int { rows.filter(\.isAgreement).count }
    public var disagreements: Int { compared - agreements }
    public var agreementRate: Double { compared == 0 ? 0 : Double(agreements) / Double(compared) }
}

public struct JevComparisonService: Sendable {
    public let classifier: JevClassifier
    public let maxConcurrentRequests: Int

    public init(classifier: JevClassifier = JevClassifier(), maxConcurrentRequests: Int = 4) {
        self.classifier = classifier
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    public func compare(entries: [ClipboardEntry], configuration: JevConfiguration, apiKey: String) async -> JevComparisonReport {
        var rows: [JevComparisonRow] = []
        var skipped = 0
        var failed = 0
        let supported = entries.filter { entry in
            guard entry.parentEntryId == nil, entry.contentType != .image, entry.contentType != .screenshot else {
                skipped += 1
                return false
            }
            return true
        }

        await withTaskGroup(of: JevComparisonRow.self) { group in
            var nextIndex = 0
            for _ in 0..<min(maxConcurrentRequests, supported.count) {
                guard nextIndex < supported.count else { break }
                let entry = supported[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        let result = try await classifier.classify(content: entry.content, configuration: configuration, apiKey: apiKey)
                        return JevComparisonRow(id: entry.id, timestamp: entry.timestamp, sourceApp: entry.sourceApp, localCategory: entry.contentType, jevCategory: result.category, confidence: result.confidence, latency: result.latency, error: nil)
                    } catch {
                        return JevComparisonRow(id: entry.id, timestamp: entry.timestamp, sourceApp: entry.sourceApp, localCategory: entry.contentType, jevCategory: nil, confidence: nil, latency: nil, error: error.localizedDescription)
                    }
                }
            }
            for await row in group {
                rows.append(row)
                if row.error != nil { failed += 1 }
                if nextIndex < supported.count {
                    let entry = supported[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let result = try await classifier.classify(content: entry.content, configuration: configuration, apiKey: apiKey)
                            return JevComparisonRow(id: entry.id, timestamp: entry.timestamp, sourceApp: entry.sourceApp, localCategory: entry.contentType, jevCategory: result.category, confidence: result.confidence, latency: result.latency, error: nil)
                        } catch {
                            return JevComparisonRow(id: entry.id, timestamp: entry.timestamp, sourceApp: entry.sourceApp, localCategory: entry.contentType, jevCategory: nil, confidence: nil, latency: nil, error: error.localizedDescription)
                        }
                    }
                }
            }
        }
        return JevComparisonReport(generatedAt: Date(), total: entries.count, compared: rows.count, skipped: skipped, failed: failed, rows: rows.sorted { $0.timestamp > $1.timestamp })
    }
}
