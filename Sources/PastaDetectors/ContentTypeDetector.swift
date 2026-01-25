import Foundation
import PastaCore

public struct ContentTypeDetector {
    public struct SplitEntry: Equatable {
        public var content: String
        public var contentType: ContentType
        /// JSON-encoded metadata for the split entry.
        public var metadataJSON: String?

        public init(content: String, contentType: ContentType, metadataJSON: String? = nil) {
            self.content = content
            self.contentType = contentType
            self.metadataJSON = metadataJSON
        }
    }

    public struct Output: Equatable {
        public var primaryType: ContentType
        public var confidence: Double
        /// JSON-encoded metadata aggregated from all detectors.
        public var metadataJSON: String?
        /// When the input is an env-var block, this contains per-var split entries.
        public var splitEntries: [SplitEntry]
        /// Extracted items from mixed content (emails, URLs, etc. found within larger text).
        public var extractedItems: [SplitEntry]

        public init(
            primaryType: ContentType,
            confidence: Double,
            metadataJSON: String? = nil,
            splitEntries: [SplitEntry] = [],
            extractedItems: [SplitEntry] = []
        ) {
            self.primaryType = primaryType
            self.confidence = confidence
            self.metadataJSON = metadataJSON
            self.splitEntries = splitEntries
            self.extractedItems = extractedItems
        }
    }

    private let emailDetector: EmailDetector
    private let phoneNumberDetector: PhoneNumberDetector
    private let ipAddressDetector: IPAddressDetector
    private let uuidDetector: UUIDDetector
    private let hashDetector: HashDetector
    private let jwtDetector: JWTDetector
    private let apiKeyDetector: APIKeyDetector
    private let envVarDetector: EnvVarDetector
    private let urlDetector: URLDetector
    private let filePathDetector: FilePathDetector
    private let codeDetector: CodeDetector
    private let shellCommandDetector: ShellCommandDetector
    private let proseDetector: ProseDetector
    private let encodingDetector: EncodingDetector

    public init(
        emailDetector: EmailDetector = EmailDetector(),
        phoneNumberDetector: PhoneNumberDetector = PhoneNumberDetector(),
        ipAddressDetector: IPAddressDetector = IPAddressDetector(),
        uuidDetector: UUIDDetector = UUIDDetector(),
        hashDetector: HashDetector = HashDetector(),
        jwtDetector: JWTDetector = JWTDetector(),
        apiKeyDetector: APIKeyDetector = APIKeyDetector(),
        envVarDetector: EnvVarDetector = EnvVarDetector(),
        urlDetector: URLDetector = URLDetector(),
        filePathDetector: FilePathDetector = FilePathDetector(),
        codeDetector: CodeDetector = CodeDetector(),
        shellCommandDetector: ShellCommandDetector = ShellCommandDetector(),
        proseDetector: ProseDetector = ProseDetector(),
        encodingDetector: EncodingDetector = EncodingDetector()
    ) {
        self.emailDetector = emailDetector
        self.phoneNumberDetector = phoneNumberDetector
        self.ipAddressDetector = ipAddressDetector
        self.uuidDetector = uuidDetector
        self.hashDetector = hashDetector
        self.jwtDetector = jwtDetector
        self.apiKeyDetector = apiKeyDetector
        self.envVarDetector = envVarDetector
        self.urlDetector = urlDetector
        self.filePathDetector = filePathDetector
        self.codeDetector = codeDetector
        self.shellCommandDetector = shellCommandDetector
        self.proseDetector = proseDetector
        self.encodingDetector = encodingDetector
    }

    public func detect(in text: String) -> Output {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Output(primaryType: .unknown, confidence: 0.0)
        }

        // Prefer analyzing decoded content when it looks URL/base64-encoded, but keep encoding metadata.
        let encodingDetections = encodingDetector.detect(in: trimmed)
        let decodedText = encodingDetections.first?.decoded
        let analysisText = decodedText ?? trimmed

        let jwt = jwtDetector.detect(in: analysisText)
        let apiKeys = apiKeyDetector.detect(in: analysisText)
        let emails = emailDetector.detect(in: analysisText)
        let phoneNumbers = phoneNumberDetector.detect(in: analysisText)
        let ipAddresses = ipAddressDetector.detect(in: analysisText)
        let uuids = uuidDetector.detect(in: analysisText)
        let hashes = hashDetector.detect(in: analysisText)
        let env = envVarDetector.detect(in: analysisText)
        let urls = urlDetector.detect(in: analysisText)
        let paths = filePathDetector.detect(in: analysisText)
        let code = codeDetector.detect(in: analysisText)
        let shellCommands = shellCommandDetector.detect(in: analysisText)
        let prose = proseDetector.detect(in: analysisText)

        let (primary, confidence) = selectPrimaryType(
            analysisText: analysisText,
            jwt: jwt,
            apiKeys: apiKeys,
            emails: emails,
            phoneNumbers: phoneNumbers,
            ipAddresses: ipAddresses,
            uuids: uuids,
            hashes: hashes,
            env: env,
            urls: urls,
            paths: paths,
            code: code,
            shellCommands: shellCommands,
            prose: prose
        )

        let splitEntries = makeSplitEntries(envOutput: env)
        let metadataJSON = buildMetadataJSON(
            originalText: trimmed,
            analysisText: analysisText,
            encoding: encodingDetections.first,
            jwt: jwt,
            apiKeys: apiKeys,
            emails: emails,
            phoneNumbers: phoneNumbers,
            ipAddresses: ipAddresses,
            uuids: uuids,
            hashes: hashes,
            env: env,
            urls: urls,
            paths: paths,
            code: code,
            shellCommands: shellCommands,
            prose: prose
        )

        // Extract individual items from mixed content (only if content is "mixed" - i.e. prose/text with embedded items)
        let extractedItems = makeExtractedItems(
            primaryType: primary,
            analysisText: analysisText,
            emails: emails,
            urls: urls,
            apiKeys: apiKeys,
            phoneNumbers: phoneNumbers,
            ipAddresses: ipAddresses,
            uuids: uuids,
            paths: paths
        )

        return Output(
            primaryType: primary,
            confidence: confidence,
            metadataJSON: metadataJSON,
            splitEntries: splitEntries,
            extractedItems: extractedItems
        )
    }

    /// Extracts individual items from mixed content.
    /// Only extracts when content is prose/text with multiple detectable items embedded.
    private func makeExtractedItems(
        primaryType: ContentType,
        analysisText: String,
        emails: [EmailDetector.Detection],
        urls: [URLDetector.Detection],
        apiKeys: [APIKeyDetector.Detection],
        phoneNumbers: [PhoneNumberDetector.Detection],
        ipAddresses: [IPAddressDetector.Detection],
        uuids: [UUIDDetector.Detection],
        paths: [FilePathDetector.Detection]
    ) -> [SplitEntry] {
        // Only extract from prose or text content
        guard primaryType == .prose || primaryType == .text else {
            return []
        }

        // Minimum content length to consider for extraction (avoid extracting from short content)
        guard analysisText.count >= 50 else {
            return []
        }

        // Count total extractable items
        let totalItems = emails.count + urls.count + apiKeys.count + phoneNumbers.count + ipAddresses.count + uuids.count + paths.count

        // Only extract if there are items to extract (and content isn't just one item)
        guard totalItems > 0 else {
            return []
        }

        // If the whole content IS a single item, don't extract (it's already the primary type)
        // This check ensures we don't duplicate when e.g. content is just "test@example.com"
        let trimmedLength = analysisText.trimmingCharacters(in: .whitespacesAndNewlines).count
        if totalItems == 1 {
            // Check if single item spans most of the content
            let singleItemLength: Int
            if let email = emails.first {
                singleItemLength = email.email.count
            } else if let url = urls.first {
                singleItemLength = url.url.count
            } else if let apiKey = apiKeys.first {
                singleItemLength = apiKey.key.count
            } else if let phone = phoneNumbers.first {
                singleItemLength = phone.phoneNumber.count
            } else if let ip = ipAddresses.first {
                singleItemLength = ip.address.count
            } else if let uuid = uuids.first {
                singleItemLength = uuid.uuid.count
            } else if let path = paths.first {
                singleItemLength = path.path.count
            } else {
                singleItemLength = 0
            }

            // If the single item is >80% of content, don't extract (it IS the content)
            if singleItemLength > 0 && Double(singleItemLength) / Double(trimmedLength) > 0.8 {
                return []
            }
        }

        var items: [SplitEntry] = []
        let maxItems = 20 // Cap extraction to avoid excessive entries

        // Extract emails
        for email in emails.prefix(maxItems - items.count) {
            let meta = jsonString(["email": email.email, "confidence": email.confidence])
            items.append(SplitEntry(content: email.email, contentType: .email, metadataJSON: meta))
        }

        // Extract URLs
        for url in urls.prefix(maxItems - items.count) {
            let meta = jsonString(["url": url.url, "domain": url.domain, "category": url.category, "confidence": url.confidence])
            items.append(SplitEntry(content: url.url, contentType: .url, metadataJSON: meta))
        }

        // Extract API keys (high value)
        for apiKey in apiKeys.prefix(maxItems - items.count) where apiKey.confidence >= 0.7 {
            let meta = jsonString(["provider": apiKey.provider, "confidence": apiKey.confidence, "isLikelyLive": apiKey.isLikelyLive])
            items.append(SplitEntry(content: apiKey.key, contentType: .apiKey, metadataJSON: meta))
        }

        // Extract phone numbers
        for phone in phoneNumbers.prefix(maxItems - items.count) {
            let meta = jsonString(["number": phone.phoneNumber, "confidence": phone.confidence])
            items.append(SplitEntry(content: phone.phoneNumber, contentType: .phoneNumber, metadataJSON: meta))
        }

        // Extract IP addresses (only public, high confidence)
        for ip in ipAddresses.prefix(maxItems - items.count) where !ip.isPrivate && !ip.isLoopback && ip.confidence >= 0.8 {
            let meta = jsonString(["address": ip.address, "version": ip.version, "confidence": ip.confidence])
            items.append(SplitEntry(content: ip.address, contentType: .ipAddress, metadataJSON: meta))
        }

        // Extract UUIDs (only high confidence)
        for uuid in uuids.prefix(maxItems - items.count) where uuid.confidence >= 0.9 {
            let meta = jsonString(["uuid": uuid.uuid, "variant": uuid.variant, "confidence": uuid.confidence])
            items.append(SplitEntry(content: uuid.uuid, contentType: .uuid, metadataJSON: meta))
        }
        
        // Extract file paths
        for path in paths.prefix(maxItems - items.count) {
            let meta = jsonString([
                "path": path.path,
                "exists": path.exists,
                "filename": path.filename,
                "fileExtension": path.fileExtension ?? "",
                "fileType": path.fileType.rawValue,
                "confidence": path.confidence
            ])
            items.append(SplitEntry(content: path.path, contentType: .filePath, metadataJSON: meta))
        }

        return items
    }

    private func selectPrimaryType(
        analysisText: String,
        jwt: [JWTDetector.Detection],
        apiKeys: [APIKeyDetector.Detection],
        emails: [EmailDetector.Detection],
        phoneNumbers: [PhoneNumberDetector.Detection],
        ipAddresses: [IPAddressDetector.Detection],
        uuids: [UUIDDetector.Detection],
        hashes: [HashDetector.Detection],
        env: EnvVarDetector.Output?,
        urls: [URLDetector.Detection],
        paths: [FilePathDetector.Detection],
        code: [CodeDetector.Detection],
        shellCommands: [ShellCommandDetector.Detection],
        prose: ProseDetector.Detection?
    ) -> (ContentType, Double) {
        let trimmed = analysisText.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalLength = trimmed.count
        
        // Helper to check if detected content covers most of the text (>= 80%)
        // This prevents labeling "Check out /path/to/file.txt for details" as .filePath
        func coversMostOfText(_ detectedContent: String) -> Bool {
            guard totalLength > 0 else { return false }
            let coverage = Double(detectedContent.count) / Double(totalLength)
            return coverage >= 0.80
        }
        
        // Priority order is the stable tiebreaker when confidences match.
        // We keep this order conservative for clipboard use.
        // API keys are high priority since they're security-sensitive.
        let priorities: [ContentType] = [
            .jwt,
            .apiKey,
            .email,
            .phoneNumber,
            .ipAddress,
            .uuid,
            .hash,
            .envVarBlock,
            .envVar,
            .shellCommand,
            .url,
            .filePath,
            .code,
            .prose,
            .text,
            .unknown
        ]

        var candidates: [(ContentType, Double)] = []
        candidates.reserveCapacity(12)

        // JWT - typically the entire content
        if let best = jwt.map(\.confidence).max() {
            candidates.append((.jwt, best))
        }
        
        // API Keys - typically the entire content
        if let best = apiKeys.map(\.confidence).max(), best >= 0.70 {
            candidates.append((.apiKey, best))
        }
        
        // Email - only if it covers most of the text (e.g., just "user@example.com")
        if let bestEmail = emails.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestEmail.email) {
                candidates.append((.email, bestEmail.confidence))
            }
        }
        
        // Phone number - only if it covers most of the text
        if let bestPhone = phoneNumbers.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestPhone.phoneNumber) {
                candidates.append((.phoneNumber, bestPhone.confidence))
            }
        }
        
        // IP Address - only if it covers most of the text
        if let bestIP = ipAddresses.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestIP.address) {
                candidates.append((.ipAddress, bestIP.confidence))
            }
        }
        
        // UUID - only if it covers most of the text
        if let bestUUID = uuids.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestUUID.uuid) {
                candidates.append((.uuid, bestUUID.confidence))
            }
        }
        
        // Hash - only if it covers most of the text
        if let bestHash = hashes.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestHash.hash) {
                candidates.append((.hash, bestHash.confidence))
            }
        }
        
        // Env vars - blocks are inherently multi-line, single vars should cover most
        if let env {
            let best = env.detections.map(\.confidence).max() ?? 0.0
            if env.isBlock {
                candidates.append((.envVarBlock, best))
            } else if let firstVar = env.detections.first {
                let varContent = firstVar.isExported ? "export \(firstVar.key)=\(firstVar.value)" : "\(firstVar.key)=\(firstVar.value)"
                if coversMostOfText(varContent) {
                    candidates.append((.envVar, best))
                }
            }
        }
        
        // Shell commands - typically cover significant portion
        if let best = shellCommands.map(\.confidence).max() {
            candidates.append((.shellCommand, best))
        }
        
        // URL - only if it covers most of the text (e.g., just "https://example.com")
        if let bestURL = urls.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestURL.url) {
                candidates.append((.url, bestURL.confidence))
            }
        }
        
        // File path - only if it covers most of the text (e.g., just "/path/to/file.txt")
        if let bestPath = paths.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestPath.path) {
                candidates.append((.filePath, bestPath.confidence))
            }
        }
        
        // Code detection - covers the whole content by design
        if let best = code.map(\.confidence).max() {
            candidates.append((.code, best))
        }
        
        // Prose detection - covers the whole content by design
        if let prose {
            candidates.append((.prose, prose.confidence))
        }

        // Fallback when nothing else matches.
        candidates.append((.text, 0.5))

        guard let best = candidates.max(by: { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            let ia = priorities.firstIndex(of: a.0) ?? priorities.count
            let ib = priorities.firstIndex(of: b.0) ?? priorities.count
            return ia > ib
        }) else {
            return (.unknown, 0.0)
        }

        // If we only matched the fallback text, and the content is tiny/noisy, call it unknown.
        if best.0 == .text, analysisText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            return (.unknown, 0.0)
        }

        return best
    }

    private func makeSplitEntries(envOutput: EnvVarDetector.Output?) -> [SplitEntry] {
        guard let envOutput, envOutput.isBlock else { return [] }

        return envOutput.detections.map { d in
            let content = d.isExported ? "export \(d.key)=\(d.value)" : "\(d.key)=\(d.value)"
            let meta: [String: Any] = ["key": d.key, "isExported": d.isExported]
            return SplitEntry(content: content, contentType: .envVar, metadataJSON: jsonString(meta))
        }
    }

    private func buildMetadataJSON(
        originalText: String,
        analysisText: String,
        encoding: EncodingDetector.Detection?,
        jwt: [JWTDetector.Detection],
        apiKeys: [APIKeyDetector.Detection],
        emails: [EmailDetector.Detection],
        phoneNumbers: [PhoneNumberDetector.Detection],
        ipAddresses: [IPAddressDetector.Detection],
        uuids: [UUIDDetector.Detection],
        hashes: [HashDetector.Detection],
        env: EnvVarDetector.Output?,
        urls: [URLDetector.Detection],
        paths: [FilePathDetector.Detection],
        code: [CodeDetector.Detection],
        shellCommands: [ShellCommandDetector.Detection],
        prose: ProseDetector.Detection?
    ) -> String? {
        var meta: [String: Any] = [:]

        if let encoding {
            // Preserve the existing encoding detector metadata format (useful for previews).
            if let encodingMeta = encoding.metadataJSON(),
               let data = encodingMeta.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: []),
               let dict = obj as? [String: Any] {
                meta["encoding"] = dict
            }
            meta["decodedEqualsOriginal"] = (analysisText == originalText)
        }

        if !jwt.isEmpty {
            let out = jwt.map { d in
                var claims: [String: Any] = [:]
                if let exp = d.claims.exp { claims["exp"] = exp.timeIntervalSince1970 }
                if let iat = d.claims.iat { claims["iat"] = iat.timeIntervalSince1970 }
                if let sub = d.claims.sub { claims["sub"] = sub }
                if let iss = d.claims.iss { claims["iss"] = iss }

                var obj: [String: Any] = [
                    "token": d.token,
                    "confidence": d.confidence,
                    "headerJSON": d.headerJSON,
                    "payloadJSON": d.payloadJSON,
                    "claims": claims
                ]
                if let isExpired = d.isExpired { obj["isExpired"] = isExpired }
                return obj
            }
            meta["jwt"] = out
        }

        if !apiKeys.isEmpty {
            meta["apiKeys"] = apiKeys.map { d in
                [
                    "key": d.key,
                    "provider": d.provider,
                    "confidence": d.confidence,
                    "isLikelyLive": d.isLikelyLive
                ] as [String: Any]
            }
        }

        if !emails.isEmpty {
            meta["emails"] = emails.map { ["email": $0.email, "confidence": $0.confidence] }
        }

        if !phoneNumbers.isEmpty {
            meta["phoneNumbers"] = phoneNumbers.map { ["number": $0.phoneNumber, "confidence": $0.confidence] }
        }

        if !ipAddresses.isEmpty {
            meta["ipAddresses"] = ipAddresses.map { detection in
                [
                    "address": detection.address,
                    "version": detection.version,
                    "isPrivate": detection.isPrivate,
                    "isLoopback": detection.isLoopback,
                    "isLinkLocal": detection.isLinkLocal,
                    "isMulticast": detection.isMulticast,
                    "confidence": detection.confidence
                ]
            }
        }

        if !uuids.isEmpty {
            meta["uuids"] = uuids.map { detection in
                var obj: [String: Any] = [
                    "uuid": detection.uuid,
                    "variant": detection.variant,
                    "confidence": detection.confidence
                ]
                if let version = detection.version {
                    obj["version"] = version
                }
                return obj
            }
        }

        if !hashes.isEmpty {
            meta["hashes"] = hashes.map { detection in
                [
                    "hash": detection.hash,
                    "kind": detection.kind,
                    "bits": detection.bitLength,
                    "confidence": detection.confidence
                ]
            }
        }

        if let env {
            meta["env"] = [
                "isBlock": env.isBlock,
                "vars": env.detections.map { ["key": $0.key, "value": $0.value, "isExported": $0.isExported, "confidence": $0.confidence] }
            ]
        }

        if !urls.isEmpty {
            meta["urls"] = urls.map { ["url": $0.url, "domain": $0.domain, "category": $0.category, "hotCount": $0.hotCount, "confidence": $0.confidence] }
        }

        if !paths.isEmpty {
            meta["filePaths"] = paths.map { d in
                var obj: [String: Any] = [
                    "path": d.path,
                    "exists": d.exists,
                    "filename": d.filename,
                    "fileType": d.fileType.rawValue,
                    "confidence": d.confidence
                ]
                if let ext = d.fileExtension { obj["extension"] = ext }
                if let mime = d.mimeType { obj["mimeType"] = mime }
                return obj
            }
        }

        if !code.isEmpty {
            meta["code"] = code.map { ["language": $0.language.rawValue, "confidence": $0.confidence] }
        }

        if !shellCommands.isEmpty {
            meta["shellCommands"] = shellCommands.map { ["command": $0.command, "executable": $0.executable, "confidence": $0.confidence] }
        }

        if let prose {
            meta["prose"] = [
                "wordCount": prose.wordCount,
                "estimatedReadingTimeSeconds": prose.estimatedReadingTimeSeconds,
                "confidence": prose.confidence
            ]
        }

        return jsonString(meta)
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
