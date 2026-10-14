import Foundation

/// Helper for parsing clipboard entry metadata to extract detected items
public struct MetadataParser {
    
    /// Extracted value with its type
    public struct ExtractedValue: Identifiable, Hashable, Sendable {
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
        .filePath, .shellCommand, .color, .macAddress, .creditCard, .iban, .code
    ]

    /// Derives the bitmask of extractable content types present in
    /// `metadata` by parsing it once. This is the single source of truth for
    /// `ClipboardEntry.contentTypeMask`: entries compute it on creation and
    /// whenever their metadata changes, and the `addContentTypeMask` migration
    /// backfills existing rows with it.
    public static func typeMask(for metadata: String?) -> ContentTypeMask {
        guard let metadata, let dict = parseJSON(metadata) else { return [] }

        var mask: ContentTypeMask = []
        if let composition = dict["composition"] as? [String: Any] {
            if composition["isMixed"] as? Bool == true { mask.insert(.mixed) }
            if (composition["itemCount"] as? Int ?? 0) > 1 { mask.insert(.multipleItems) }
        }
        if hasItems(dict, key: "emails") { mask.insert(.email) }
        if hasItems(dict, key: "urls") { mask.insert(.url) }
        if hasItems(dict, key: "phoneNumbers") { mask.insert(.phoneNumber) }
        if hasItems(dict, key: "ipAddresses") { mask.insert(.ipAddress) }
        if hasItems(dict, key: "uuids") { mask.insert(.uuid) }
        if hasItems(dict, key: "hashes") { mask.insert(.hash) }
        if hasItems(dict, key: "apiKeys") { mask.insert(.apiKey) }
        if hasItems(dict, key: "jwt") { mask.insert(.jwt) }
        if hasItems(dict, key: "filePaths") { mask.insert(.filePath) }
        if hasItems(dict, key: "shellCommands") { mask.insert(.shellCommand) }
        if hasItems(dict, key: "colors") { mask.insert(.color) }
        if hasItems(dict, key: "macAddresses") { mask.insert(.macAddress) }
        if hasItems(dict, key: "creditCards") { mask.insert(.creditCard) }
        if hasItems(dict, key: "ibans") { mask.insert(.iban) }
        if (dict["code"] as? [[String: Any]])?.contains(where: { $0["location"] as? Int != nil }) == true {
            mask.insert(.code)
        }

        if let env = dict["env"] as? [String: Any] {
            mask.insert(.envVar)
            if (env["isBlock"] as? Bool) == true {
                mask.insert(.envVarBlock)
            }
        }

        return mask
    }

    /// Check if a metadata string contains items of a given type.
    ///
    /// Parses the metadata on every call. Callers holding a `ClipboardEntry`
    /// should test `entry.contentTypeMask` instead, which was computed once at
    /// insert time and persisted.
    public static func containsType(_ type: ContentType, in metadata: String?) -> Bool {
        guard let bit = ContentTypeMask(type), let metadata else { return false }
        return typeMask(for: metadata).contains(bit)
    }
    
    /// Extract all values of a given type from metadata
    public static func extractValues(for type: ContentType, from metadata: String?, content: String? = nil) -> [ExtractedValue] {
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
        case .color, .macAddress, .creditCard, .iban, .code:
            return extractAdditionalValues(from: dict, content: content).filter { $0.type == type }
        default:
            return []
        }
    }
    
    /// Extract all detected values from metadata (all types)
    public static func extractAllValues(from metadata: String?, content: String? = nil) -> [ExtractedValue] {
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
        values.append(contentsOf: extractCustomDetections(from: dict))
        values.append(contentsOf: extractAdditionalValues(from: dict, content: content))
        
        return values
    }

    /// Extract detected values from metadata up to a maximum count.
    public static func extractAllValues(from metadata: String?, limit: Int, content: String? = nil) -> [ExtractedValue] {
        guard limit > 0 else { return [] }
        guard let metadata = metadata, let dict = parseJSON(metadata) else { return [] }

        var values: [ExtractedValue] = []
        values.reserveCapacity(min(limit, 64))

        func appendLimited(_ newValues: [ExtractedValue]) {
            guard values.count < limit else { return }
            let remaining = limit - values.count
            values.append(contentsOf: newValues.prefix(remaining))
        }

        appendLimited(extractEmails(from: dict))
        appendLimited(extractURLs(from: dict))
        appendLimited(extractPhoneNumbers(from: dict))
        appendLimited(extractIPAddresses(from: dict))
        appendLimited(extractUUIDs(from: dict))
        appendLimited(extractHashes(from: dict))
        appendLimited(extractAPIKeys(from: dict, limit: max(0, limit - values.count)))
        appendLimited(extractJWTs(from: dict))
        appendLimited(extractEnvVars(from: dict, blockOnly: false))
        appendLimited(extractFilePaths(from: dict))
        appendLimited(extractShellCommands(from: dict))
        appendLimited(extractCustomDetections(from: dict))
        appendLimited(extractAdditionalValues(from: dict, content: content))

        return values
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
    
    private static func extractAPIKeys(from dict: [String: Any], limit: Int? = nil) -> [ExtractedValue] {
        guard let items = dict["apiKeys"] as? [[String: Any]] else { return [] }

        var values: [ExtractedValue] = []
        values.reserveCapacity(limit.map { min($0, items.count) } ?? items.count)

        for item in items {
            guard let key = item["key"] as? String else { continue }
            let provider = item["provider"] as? String
            let display = provider.map { "\($0): \(key)" } ?? key
            values.append(ExtractedValue(type: .apiKey, value: key, displayValue: display))

            if let limit, values.count >= limit {
                break
            }
        }

        return values
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
            let display = item["raw"] as? String ?? ((item["isExported"] as? Bool == true ? "export " : "") + "\(key)=\(value)")
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

    private static func extractCustomDetections(from dict: [String: Any]) -> [ExtractedValue] {
        guard let items = dict["customDetectors"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, let value = item["value"] as? String else { return nil }
            let display = "\(name): \(value)"
            return ExtractedValue(type: .text, value: value, displayValue: display)
        }
    }

    private static func extractAdditionalValues(from dict: [String: Any], content: String?) -> [ExtractedValue] {
        var values: [ExtractedValue] = []
        for (key, field, type) in [
            ("colors", "raw", ContentType.color),
            ("macAddresses", "raw", .macAddress),
            ("ibans", "raw", .iban)
        ] {
            for item in dict[key] as? [[String: Any]] ?? [] {
                guard let value = item[field] as? String ?? (type == .iban ? item["iban"] as? String : nil),
                      !value.isEmpty else { continue }
                values.append(ExtractedValue(type: type, value: value))
            }
        }
        // Source ranges preserve exact snippets without duplicating card numbers in metadata.
        let decoded = (dict["encoding"] as? [String: Any])?["decodedPreview"] as? String
        if let source = decoded ?? content {
            let analyzed = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContentComposition.analysisLimit))
            for (key, type) in [("creditCards", ContentType.creditCard), ("code", .code)] {
                for item in dict[key] as? [[String: Any]] ?? [] {
                    guard let location = item["location"] as? Int, let length = item["length"] as? Int,
                          location >= 0, length > 0, location <= analyzed.utf16.count,
                          length <= analyzed.utf16.count - location,
                          let range = Range(NSRange(location: location, length: length), in: analyzed) else { continue }
                    let value = String(analyzed[range])
                    values.append(ExtractedValue(type: type, value: value, displayValue: item["masked"] as? String))
                }
            }
        }
        return values
    }
}


// MARK: - ClipboardEntry Extension

extension ClipboardEntry {
    /// Check if this entry contains items of the given type (either as primary type or in metadata)
    public func containsType(_ type: ContentType) -> Bool {
        if contentType == type { return true }
        return contentTypeMask.contains(type)
    }
    
    /// Get all extracted values of a specific type from this entry's metadata
    public func extractedValues(for type: ContentType) -> [MetadataParser.ExtractedValue] {
        // Only card and code snippets slice the content; other types never
        // read it, so don't load a lazy history row's full text for them.
        let usesContent = type == .creditCard || type == .code
        return MetadataParser.extractValues(for: type, from: metadata, content: usesContent ? content : nil)
    }
    
    /// Get all extracted values from this entry's metadata
    public var allExtractedValues: [MetadataParser.ExtractedValue] {
        MetadataParser.extractAllValues(from: metadata, content: content)
    }
}
