import Foundation
import Security

/// Where Pasta sends text to be turned into embedding vectors.
///
/// Every provider speaks the OpenAI `/embeddings` wire format, so one client
/// covers OpenAI, Azure OpenAI (Microsoft) and local OpenAI-compatible
/// servers such as Ollama or LM Studio.
public enum EmbeddingProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI
    case azureOpenAI
    case openAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .azureOpenAI: return "Azure OpenAI"
        case .openAICompatible: return "OpenAI-compatible (Ollama, LM Studio…)"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1/embeddings"
        case .azureOpenAI: return "https://YOUR-RESOURCE.openai.azure.com/openai/v1/embeddings"
        case .openAICompatible: return "http://localhost:11434/v1/embeddings"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI, .azureOpenAI: return "text-embedding-3-small"
        case .openAICompatible: return "nomic-embed-text"
        }
    }

    /// Local servers usually run without authentication.
    public var requiresAPIKey: Bool { self != .openAICompatible }

    var keychainService: String { "com.pasta.semantic-search.\(rawValue).api-key" }
}

public enum SemanticSearchError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidEndpoint
    case validationRequired
    case invalidResponse(String)
    case unauthorized(String?)
    case forbidden(String?)
    case endpointNotFound
    case badRequest(String?)
    case rateLimited
    case server(status: Int)
    case unexpectedStatus(Int, String?)
    case timedOut
    case network(code: Int, description: String)
    case keychainFailure(operation: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key for this embeddings provider in Settings → Search."
        case .invalidEndpoint:
            return "Use a full HTTPS embeddings endpoint (plain HTTP is only allowed for localhost) without credentials or a fragment."
        case .validationRequired:
            return "Test this embeddings provider in Settings → Search before enabling semantic search."
        case .invalidResponse(let detail):
            return "The embeddings provider returned an unexpected response: \(detail)"
        case .unauthorized(let detail):
            return Self.join("The embeddings provider rejected the API key (401).", detail)
        case .forbidden(let detail):
            return Self.join("The embeddings provider denied access to the model (403).", detail)
        case .endpointNotFound:
            return "The embeddings endpoint returned 404. Check the endpoint URL and model or deployment name."
        case .badRequest(let detail):
            return Self.join("The embeddings provider rejected the request (400). Check the model name.", detail)
        case .rateLimited:
            return "The embeddings provider's rate limit was reached (429). Indexing will resume later."
        case .server(let status):
            return "The embeddings provider returned a server error (\(status))."
        case .unexpectedStatus(let status, let detail):
            return Self.join("The embeddings provider returned HTTP \(status).", detail)
        case .timedOut:
            return "The embeddings request timed out."
        case .network(_, let description):
            return description
        case .keychainFailure(let operation, let status):
            return "Could not \(operation) the embeddings API key in Keychain (status \(status))."
        }
    }

    /// Errors that will fail every following request too, so indexing waits
    /// for the configuration to change instead of retrying on a timer.
    public var requiresConfigurationChange: Bool {
        switch self {
        case .missingAPIKey, .invalidEndpoint, .validationRequired, .unauthorized, .forbidden, .endpointNotFound, .badRequest:
            return true
        default:
            return false
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .timedOut: return true
        case .unexpectedStatus(let status, _): return status == 408
        case .network(let code, _):
            return code == URLError.networkConnectionLost.rawValue || code == URLError.cannotConnectToHost.rawValue
        default: return false
        }
    }

    static func from(status: Int, body: Data) -> SemanticSearchError {
        let detail = JevAPIError.errorDetail(from: body)
        switch status {
        case 400, 422: return .badRequest(detail)
        case 401: return .unauthorized(detail)
        case 403: return .forbidden(detail)
        case 404: return .endpointNotFound
        case 429: return .rateLimited
        case 500..<600: return .server(status: status)
        default: return .unexpectedStatus(status, detail)
        }
    }

    init(_ error: URLError) {
        self = error.code == .timedOut ? .timedOut : .network(code: error.code.rawValue, description: error.localizedDescription)
    }

    private static func join(_ summary: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return summary }
        return "\(summary) \(detail)"
    }
}

/// User-visible semantic search settings, persisted in `UserDefaults`.
///
/// Semantic search is off by default. It can only be enabled after the exact
/// provider, endpoint, model and key have passed "Save & Test", mirroring the
/// remote classification providers.
public struct SemanticSearchConfiguration: Sendable, Equatable {
    /// Bump when `SemanticDocument` changes so stored vectors are rebuilt.
    public static let documentVersion = 1
    /// `text-embedding-3-*` models are shortened to this many dimensions,
    /// which keeps memory and storage small with negligible quality loss.
    public static let reducedDimensions = 512

    enum Keys {
        static let prefix = "pasta.semanticSearch"
        static let enabled = "\(prefix).enabled"
        static let provider = "\(prefix).provider"
        static let validated = "\(prefix).validatedConfiguration"
        static func endpoint(_ provider: EmbeddingProviderKind) -> String { "\(prefix).\(provider.rawValue).endpoint" }
        static func model(_ provider: EmbeddingProviderKind) -> String { "\(prefix).\(provider.rawValue).model" }
    }

    public var isEnabled: Bool
    public var provider: EmbeddingProviderKind
    public var endpoint: String
    public var model: String

    public init(
        isEnabled: Bool = false,
        provider: EmbeddingProviderKind = .openAI,
        endpoint: String? = nil,
        model: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.provider = provider
        self.endpoint = endpoint ?? provider.defaultEndpoint
        self.model = model ?? provider.defaultModel
    }

    public static func load(defaults: UserDefaults = .standard) -> SemanticSearchConfiguration {
        let provider = EmbeddingProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .openAI
        return load(provider: provider, isEnabled: defaults.bool(forKey: Keys.enabled), defaults: defaults)
    }

    /// The stored endpoint/model for `provider`, so switching providers in
    /// Settings restores what was last typed for each.
    public static func load(provider: EmbeddingProviderKind, isEnabled: Bool = false, defaults: UserDefaults = .standard) -> SemanticSearchConfiguration {
        SemanticSearchConfiguration(
            isEnabled: isEnabled,
            provider: provider,
            endpoint: nonEmpty(defaults.string(forKey: Keys.endpoint(provider))),
            model: nonEmpty(defaults.string(forKey: Keys.model(provider)))
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.endpoint(provider))
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model(provider))
    }

    public var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// HTTPS, or plain HTTP to a loopback host. No embedded credentials or fragment.
    public var endpointURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            return nil
        }
        if scheme == "https" { return url }
        if scheme == "http", Self.isLoopback(host: host) { return url }
        return nil
    }

    /// Text sent to a loopback server never leaves the Mac, so the privacy
    /// exclusions for remote providers do not apply.
    public var isOnDevice: Bool {
        guard let host = endpointURL?.host else { return false }
        return Self.isLoopback(host: host)
    }

    /// Dimensions to request, or `nil` to accept the model's native size.
    public var requestedDimensions: Int? {
        provider != .openAICompatible && effectiveModel.hasPrefix("text-embedding-3") ? Self.reducedDimensions : nil
    }

    /// Identifies the vector space stored vectors belong to. Vectors under a
    /// different key are discarded and rebuilt.
    public var indexKey: String {
        let dimensions = requestedDimensions.map(String.init) ?? "native"
        return "\(provider.rawValue)|\(endpointIdentity)|\(effectiveModel)|\(dimensions)|doc\(Self.documentVersion)"
    }

    /// Scheme, host, port and path of the endpoint, so two services on one
    /// host never share vectors.
    var endpointIdentity: String {
        guard let url = endpointURL, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return "invalid"
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let query = url.query.map { "?\($0)" } ?? ""
        return "\(scheme)://\(host):\(port)\(path)\(query)"
    }

    public func isValidated(apiKey: String?, defaults: UserDefaults = .standard) -> Bool {
        guard endpointURL != nil else { return false }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if provider.requiresAPIKey && key.isEmpty { return false }
        return defaults.string(forKey: Keys.validated) == validationFingerprint(apiKey: key)
    }

    public func isActive(apiKey: String?, defaults: UserDefaults = .standard) -> Bool {
        isEnabled && isValidated(apiKey: apiKey, defaults: defaults)
    }

    public func recordSuccessfulValidation(apiKey: String?, defaults: UserDefaults = .standard) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        defaults.set(validationFingerprint(apiKey: key), forKey: Keys.validated)
    }

    public static func invalidateValidation(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.validated)
        defaults.set(false, forKey: Keys.enabled)
    }

    private func validationFingerprint(apiKey: String) -> String {
        let values = [provider.rawValue, endpoint.trimmingCharacters(in: .whitespacesAndNewlines), effectiveModel, apiKey]
        return ClipboardEntry.sha256Hex(values.map { "\($0.utf8.count):\($0)" }.joined())
    }

    /// `localhost`, or a literal loopback address (127.0.0.0/8 or ::1).
    /// Names that merely look numeric, such as `127.example.com`, are not.
    static func isLoopback(host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, normalized, &ipv4) == 1 {
            return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { bytes in bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
        }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Embedding API keys, stored separately from the classification keys.
public enum SemanticSearchKeychain {
    public static func read(provider: EmbeddingProviderKind) throws -> String? {
#if os(macOS)
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SemanticSearchError.keychainFailure(operation: "read", status: status)
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    public static func save(_ key: String, provider: EmbeddingProviderKind) throws {
#if os(macOS)
        let query = baseQuery(provider)
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SemanticSearchError.keychainFailure(operation: "save", status: updateStatus)
            }
        } else if status != errSecSuccess {
            throw SemanticSearchError.keychainFailure(operation: "save", status: status)
        }
#endif
    }

    public static func remove(provider: EmbeddingProviderKind) throws {
#if os(macOS)
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SemanticSearchError.keychainFailure(operation: "remove", status: status)
        }
#endif
    }

    private static func baseQuery(_ provider: EmbeddingProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: "default"
        ]
    }
}
