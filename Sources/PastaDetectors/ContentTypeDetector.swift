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

    public struct CustomDetection: Equatable {
        public var name: String
        public var value: String
        public var confidence: Double

        public init(name: String, value: String, confidence: Double) {
            self.name = name
            self.value = value
            self.confidence = confidence
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
        /// Matches from user-defined custom detectors.
        public var customDetections: [CustomDetection]

        public init(
            primaryType: ContentType,
            confidence: Double,
            metadataJSON: String? = nil,
            splitEntries: [SplitEntry] = [],
            extractedItems: [SplitEntry] = [],
            customDetections: [CustomDetection] = []
        ) {
            self.primaryType = primaryType
            self.confidence = confidence
            self.metadataJSON = metadataJSON
            self.splitEntries = splitEntries
            self.extractedItems = extractedItems
            self.customDetections = customDetections
        }
    }

    let emailDetector: EmailDetector
    let phoneNumberDetector: PhoneNumberDetector
    let ipAddressDetector: IPAddressDetector
    let uuidDetector: UUIDDetector
    let hashDetector: HashDetector
    let jwtDetector: JWTDetector
    let apiKeyDetector: APIKeyDetector
    let envVarDetector: EnvVarDetector
    let urlDetector: URLDetector
    let filePathDetector: FilePathDetector
    let codeDetector: CodeDetector
    let shellCommandDetector: ShellCommandDetector
    let proseDetector: ProseDetector
    let encodingDetector: EncodingDetector
    let colorDetector: ColorDetector
    let macAddressDetector: MACAddressDetector
    let creditCardDetector: CreditCardDetector
    let ibanDetector: IBANDetector

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
        encodingDetector: EncodingDetector = EncodingDetector(),
        colorDetector: ColorDetector = ColorDetector(),
        macAddressDetector: MACAddressDetector = MACAddressDetector(),
        creditCardDetector: CreditCardDetector = CreditCardDetector(),
        ibanDetector: IBANDetector = IBANDetector()
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
        self.colorDetector = colorDetector
        self.macAddressDetector = macAddressDetector
        self.creditCardDetector = creditCardDetector
        self.ibanDetector = ibanDetector
    }

    public func detect(in text: String, configuration: DetectorConfiguration = .default) -> Output {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Output(primaryType: .unknown, confidence: 0.0)
        }

        // Trivial inputs can't meaningfully produce any of the structured types —
        // short-circuit before paying for ~14 detector passes (each scanning the
        // string, building NSRanges, etc.).
        if trimmed.count < 2 {
            return Output(primaryType: .text, confidence: 0.5)
        }

        // Prefer analyzing decoded content when it looks URL/base64-encoded, but keep encoding metadata.
        let encodingDetections = encodingDetector.detect(in: trimmed)
        let decodedText = encodingDetections.first?.decoded
        let analysisText = decodedText ?? trimmed

        let jwt = detectJWT(in: analysisText, configuration: configuration)
        let rawApiKeys = detectAPIKeys(in: analysisText, configuration: configuration)
        
        // Suppress API key detections that are substrings of detected JWT tokens.
        // JWT base64url segments frequently match broad API key patterns.
        let apiKeys: [APIKeyDetector.Detection]
        if jwt.isEmpty {
            apiKeys = rawApiKeys
        } else {
            let jwtTokens = jwt.map(\.token)
            apiKeys = rawApiKeys.filter { detection in
                !jwtTokens.contains { $0.contains(detection.key) }
            }
        }
        let emails = detectEmails(in: analysisText, configuration: configuration)
        let phoneNumbers = detectPhoneNumbers(in: analysisText, configuration: configuration)
        let ipAddresses = detectIPAddresses(in: analysisText, configuration: configuration)
        let uuids = detectUUIDs(in: analysisText, configuration: configuration)
        let hashes = detectHashes(in: analysisText, configuration: configuration)
        let env = detectEnvVars(in: analysisText, configuration: configuration)
        let urls = detectURLs(in: analysisText, configuration: configuration)
        let paths = detectFilePaths(in: analysisText, configuration: configuration)
        let code = codeDetector.detect(in: analysisText)
        let shellCommands = detectShellCommands(in: analysisText, configuration: configuration)
        let prose = proseDetector.detect(in: analysisText)
        let colors = detectColors(in: analysisText, configuration: configuration)
        let macAddresses = detectMACAddresses(in: analysisText, configuration: configuration)
        let creditCards = detectCreditCards(in: analysisText, configuration: configuration)
        let ibans = detectIBANs(in: analysisText, configuration: configuration)
        let customDetections = detectCustomDetections(in: analysisText, configuration: configuration)

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
            prose: prose,
            colors: colors,
            macAddresses: macAddresses,
            creditCards: creditCards,
            ibans: ibans
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
            prose: prose,
            colors: colors,
            macAddresses: macAddresses,
            creditCards: creditCards,
            ibans: ibans,
            customDetections: customDetections
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
            paths: paths,
            customDetections: customDetections
        )

        return Output(
            primaryType: primary,
            confidence: confidence,
            metadataJSON: metadataJSON,
            splitEntries: splitEntries,
            extractedItems: extractedItems,
            customDetections: customDetections
        )
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
        prose: ProseDetector.Detection?,
        colors: [ColorDetector.Detection],
        macAddresses: [MACAddressDetector.Detection],
        creditCards: [CreditCardDetector.Detection],
        ibans: [IBANDetector.Detection]
    ) -> (ContentType, Double) {
        let trimmed = analysisText.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalLength = trimmed.count
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        
        // Helper to check if detected content covers most of the text (>= 80%)
        // This prevents labeling "Check out /path/to/file.txt for details" as .filePath
        func coversMostOfText(_ detectedContent: String) -> Bool {
            guard totalLength > 0 else { return false }
            let coverage = Double(detectedContent.count) / Double(totalLength)
            return coverage >= 0.80
        }
        
        func isShortContext(_ detectedContent: String) -> Bool {
            let extra = max(0, totalLength - detectedContent.count)
            return extra <= 8 || (wordCount <= 3 && extra <= 12)
        }
        
        // Priority order is the stable tiebreaker when confidences match.
        // We keep this order conservative for clipboard use.
        // API keys are high priority since they're security-sensitive.
        let priorities: [ContentType] = [
            .jwt,
            .apiKey,
            .creditCard,
            .iban,
            .email,
            .phoneNumber,
            .macAddress,
            .ipAddress,
            .uuid,
            .color,
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
        // Pre-build a lookup so the tiebreaker comparator below is O(1) per
        // candidate instead of an O(n) `firstIndex(of:)` scan repeated for
        // every pairwise comparison in `candidates.max`.
        var priorityIndex: [ContentType: Int] = [:]
        priorityIndex.reserveCapacity(priorities.count)
        for (i, type) in priorities.enumerated() {
            priorityIndex[type] = i
        }

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
            if coversMostOfText(bestIP.address) || isShortContext(bestIP.address) {
                candidates.append((.ipAddress, bestIP.confidence))
            }
        }
        
        // UUID - only if it covers most of the text
        if let bestUUID = uuids.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestUUID.uuid) {
                candidates.append((.uuid, bestUUID.confidence))
            }
        }

        // Color - short literal that should cover most of the text
        if let bestColor = colors.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestColor.raw) || isShortContext(bestColor.raw) {
                candidates.append((.color, bestColor.confidence))
            }
        }
        
        // Hash - only if it covers most of the text
        if let bestHash = hashes.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestHash.hash) {
                candidates.append((.hash, bestHash.confidence))
            }
        }

        // MAC address - cover most of text or short context
        if let bestMAC = macAddresses.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestMAC.raw) || isShortContext(bestMAC.raw) {
                candidates.append((.macAddress, bestMAC.confidence))
            }
        }

        // Credit card - high priority, only if it covers most of text
        if let bestCC = creditCards.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestCC.raw) || isShortContext(bestCC.raw) {
                candidates.append((.creditCard, bestCC.confidence))
            }
        }

        // IBAN - only if covers most of text or short context
        if let bestIBAN = ibans.max(by: { $0.confidence < $1.confidence }) {
            if coversMostOfText(bestIBAN.raw) || isShortContext(bestIBAN.raw) {
                candidates.append((.iban, bestIBAN.confidence))
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
            let ia = priorityIndex[a.0] ?? priorities.count
            let ib = priorityIndex[b.0] ?? priorities.count
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
}
