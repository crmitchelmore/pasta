import Foundation

/// Helper for parsing clipboard entry metadata to extract detected items
public struct MetadataParser {
    
    /// Extracted value with its type
    public struct ExtractedValue: Identifiable, Hashable {
        public let id = UUID()
        public let type: ContentType
        public let value: String
        public let displayValue: String
        
        public init(type: ContentType, value: String, displayValue: String? = nil) {
            self.type = type
            self.value = value
            self.displayValue = displayValue ?? value
        }
    }
    
    /// Content types that can be extracted from metadata
    public static let extractableTypes: Set<ContentType> = [
        .email, .url, .phoneNumber, .ipAddress, .uuid,
        .hash, .apiKey, .jwt,
        .envVar, .envVarBlock,
        .filePath, .shellCommand
    ]
    
    /// Check if an entry's metadata contains items of a given type
    public static func containsType(_ type: ContentType, in metadata: String?) -> Bool {
        guard let metadata = metadata, let dict = parseJSON(metadata) else { return false }
        
        switch type {
        case .email:
            return hasItems(dict, key: "emails")
        case .url:
            return hasItems(dict, key: "urls")
        case .phoneNumber:
            return hasItems(dict, key: "phoneNumbers")
        case .ipAddress:
            return hasItems(dict, key: "ipAddresses")
        case .uuid:
            return hasItems(dict, key: "uuids")
        case .hash:
            return hasItems(dict, key: "hashes")
        case .apiKey:
            return hasItems(dict, key: "apiKeys")
        case .jwt:
            return hasItems(dict, key: "jwt")
        case .envVar:
            return (dict["env"] as? [String: Any]) != nil
        case .envVarBlock:
            guard let env = dict["env"] as? [String: Any] else { return false }
            return (env["isBlock"] as? Bool) == true
        case .filePath:
            return hasItems(dict, key: "filePaths")
        case .shellCommand:
            return hasItems(dict, key: "shellCommands")
        default:
            return false
        }
    }
    
    /// Extract all values of a given type from metadata
    public static func extractValues(for type: ContentType, from metadata: String?) -> [ExtractedValue] {
        guard let metadata = metadata, let dict = parseJSON(metadata) else { return [] }
        
        switch type {
        case .email:
            return extractEmails(from: dict)
        case .url:
            return extractURLs(from: dict)
        case .phoneNumber:
            return extractPhoneNumbers(from: dict)
        case .ipAddress:
            return extractIPAddresses(from: dict)
        case .uuid:
            return extractUUIDs(from: dict)
        case .hash:
            return extractHashes(from: dict)
        case .apiKey:
            return extractAPIKeys(from: dict)
        case .jwt:
            return extractJWTs(from: dict)
        case .envVar:
            return extractEnvVars(from: dict, blockOnly: false)
        case .envVarBlock:
            return extractEnvVars(from: dict, blockOnly: true)
        case .filePath:
            return extractFilePaths(from: dict)
        case .shellCommand:
            return extractShellCommands(from: dict)
        default:
            return []
        }
    }
    
    /// Extract all detected values from metadata (all types)
    public static func extractAllValues(from metadata: String?) -> [ExtractedValue] {
        guard let metadata = metadata, let dict = parseJSON(metadata) else { return [] }
        
        var values: [ExtractedValue] = []
        values.append(contentsOf: extractEmails(from: dict))
        values.append(contentsOf: extractURLs(from: dict))
        values.append(contentsOf: extractPhoneNumbers(from: dict))
        values.append(contentsOf: extractIPAddresses(from: dict))
        values.append(contentsOf: extractUUIDs(from: dict))
        values.append(contentsOf: extractHashes(from: dict))
        values.append(contentsOf: extractAPIKeys(from: dict))
        values.append(contentsOf: extractJWTs(from: dict))
        values.append(contentsOf: extractEnvVars(from: dict, blockOnly: false))
        values.append(contentsOf: extractFilePaths(from: dict))
        values.append(contentsOf: extractShellCommands(from: dict))
        
        return values
    }
    
    /// Get count of extracted items of a type from metadata
    public static func countItems(of type: ContentType, in metadata: String?) -> Int {
        guard let metadata = metadata, let dict = parseJSON(metadata) else { return 0 }
        
        switch type {
        case .email:
            return (dict["emails"] as? [[String: Any]])?.count ?? 0
        case .url:
            return (dict["urls"] as? [[String: Any]])?.count ?? 0
        case .phoneNumber:
            return (dict["phoneNumbers"] as? [[String: Any]])?.count ?? 0
        case .ipAddress:
            return (dict["ipAddresses"] as? [[String: Any]])?.count ?? 0
        case .uuid:
            return (dict["uuids"] as? [[String: Any]])?.count ?? 0
        case .hash:
            return (dict["hashes"] as? [[String: Any]])?.count ?? 0
        case .apiKey:
            return (dict["apiKeys"] as? [[String: Any]])?.count ?? 0
        case .jwt:
            return (dict["jwt"] as? [[String: Any]])?.count ?? 0
        case .envVar:
            return ((dict["env"] as? [String: Any])?["vars"] as? [[String: Any]])?.count ?? 0
        case .envVarBlock:
            guard let env = dict["env"] as? [String: Any], (env["isBlock"] as? Bool) == true else { return 0 }
            return (env["vars"] as? [[String: Any]])?.count ?? 0
        case .filePath:
            return (dict["filePaths"] as? [[String: Any]])?.count ?? 0
        case .shellCommand:
            return (dict["shellCommands"] as? [[String: Any]])?.count ?? 0
        case .code:
            return (dict["code"] as? [[String: Any]])?.count ?? 0
        default:
            return 0
        }
    }
    
    // MARK: - Private Helpers
    
    private static func parseJSON(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }
    
    private static func hasItems(_ dict: [String: Any], key: String) -> Bool {
        guard let items = dict[key] as? [[String: Any]] else { return false }
        return !items.isEmpty
    }
    
    private static func extractEmails(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["emails"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let email = item["email"] as? String else { return nil }
            return ExtractedValue(type: .email, value: email)
        }
    }
    
    private static func extractURLs(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["urls"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            let domain = item["domain"] as? String ?? url
            return ExtractedValue(type: .url, value: url, displayValue: domain)
        }
    }
    
    private static func extractPhoneNumbers(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["phoneNumbers"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let number = item["number"] as? String else { return nil }
            return ExtractedValue(type: .phoneNumber, value: number)
        }
    }
    
    private static func extractIPAddresses(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["ipAddresses"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let address = item["address"] as? String else { return nil }
            let version = item["version"] as? String ?? ""
            let display = version.isEmpty ? address : "\(address) (\(version.uppercased()))"
            return ExtractedValue(type: .ipAddress, value: address, displayValue: display)
        }
    }
    
    private static func extractUUIDs(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["uuids"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let uuid = item["uuid"] as? String else { return nil }
            return ExtractedValue(type: .uuid, value: uuid)
        }
    }
    
    private static func extractHashes(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["hashes"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let hash = item["hash"] as? String else { return nil }
            let kind = item["kind"] as? String
            let display = kind.map { "\($0.uppercased()): \(hash)" } ?? hash
            return ExtractedValue(type: .hash, value: hash, displayValue: display)
        }
    }
    
    private static func extractAPIKeys(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["apiKeys"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            let provider = item["provider"] as? String
            let display = provider.map { "\($0): \(key)" } ?? key
            return ExtractedValue(type: .apiKey, value: key, displayValue: display)
        }
    }
    
    private static func extractJWTs(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["jwt"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let token = item["token"] as? String else { return nil }
            let isExpired = item["isExpired"] as? Bool
            let display = isExpired == true ? "JWT (expired)" : "JWT"
            return ExtractedValue(type: .jwt, value: token, displayValue: display)
        }
    }
    
    private static func extractEnvVars(from dict: [String: Any], blockOnly: Bool) -> [ExtractedValue] {
        guard let env = dict["env"] as? [String: Any],
              let vars = env["vars"] as? [[String: Any]]
        else { return [] }
        
        if blockOnly, (env["isBlock"] as? Bool) != true {
            return []
        }
        
        return vars.compactMap { item in
            guard let key = item["key"] as? String else { return nil }
            let value = item["value"] as? String ?? ""
            let display = value.isEmpty ? key : "\(key)=\(value)"
            return ExtractedValue(type: .envVar, value: display, displayValue: display)
        }
    }
    
    private static func extractFilePaths(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["filePaths"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let path = item["path"] as? String else { return nil }
            return ExtractedValue(type: .filePath, value: path)
        }
    }
    
    private static func extractShellCommands(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["shellCommands"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let command = item["command"] as? String else { return nil }
            let exec = item["executable"] as? String
            let display = exec.map { "\($0): \(command)" } ?? command
            return ExtractedValue(type: .shellCommand, value: command, displayValue: display)
        }
    }
    
    private static func extractCodeLanguages(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["code"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let lang = item["language"] as? String else { return nil }
            return ExtractedValue(type: .code, value: lang, displayValue: lang.uppercased())
        }
    }
}


// MARK: - ClipboardEntry Extension

extension ClipboardEntry {
    /// Check if this entry contains items of the given type (either as primary type or in metadata)
    public func containsType(_ type: ContentType) -> Bool {
        if contentType == type { return true }
        return MetadataParser.containsType(type, in: metadata)
    }
    
    /// Get all extracted values of a specific type from this entry's metadata
    public func extractedValues(for type: ContentType) -> [MetadataParser.ExtractedValue] {
        MetadataParser.extractValues(for: type, from: metadata)
    }
    
    /// Get all extracted values from this entry's metadata
    public var allExtractedValues: [MetadataParser.ExtractedValue] {
        MetadataParser.extractAllValues(from: metadata)
    }
}
