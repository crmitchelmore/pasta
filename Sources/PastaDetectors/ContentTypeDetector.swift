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

        public init(primaryType: ContentType, confidence: Double, metadataJSON: String? = nil, splitEntries: [SplitEntry] = []) {
            self.primaryType = primaryType
            self.confidence = confidence
            self.metadataJSON = metadataJSON
            self.splitEntries = splitEntries
        }
    }

    private let emailDetector: EmailDetector
    private let phoneNumberDetector: PhoneNumberDetector
    private let ipAddressDetector: IPAddressDetector
    private let uuidDetector: UUIDDetector
    private let hashDetector: HashDetector
    private let jwtDetector: JWTDetector
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

        return Output(primaryType: primary, confidence: confidence, metadataJSON: metadataJSON, splitEntries: splitEntries)
    }

    private func selectPrimaryType(
        analysisText: String,
        jwt: [JWTDetector.Detection],
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
        // Priority order is the stable tiebreaker when confidences match.
        // We keep this order conservative for clipboard use.
        let priorities: [ContentType] = [
            .jwt,
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
        candidates.reserveCapacity(10)

        if let best = jwt.map(\.confidence).max() {
            candidates.append((.jwt, best))
        }
        if let best = emails.map(\.confidence).max() {
            candidates.append((.email, best))
        }
        if let best = phoneNumbers.map(\.confidence).max() {
            candidates.append((.phoneNumber, best))
        }
        if let best = ipAddresses.map(\.confidence).max() {
            candidates.append((.ipAddress, best))
        }
        if let best = uuids.map(\.confidence).max() {
            candidates.append((.uuid, best))
        }
        if let best = hashes.map(\.confidence).max() {
            candidates.append((.hash, best))
        }
        if let env {
            let best = env.detections.map(\.confidence).max() ?? 0.0
            candidates.append((env.isBlock ? .envVarBlock : .envVar, best))
        }
        if let best = shellCommands.map(\.confidence).max() {
            candidates.append((.shellCommand, best))
        }
        if let best = urls.map(\.confidence).max() {
            candidates.append((.url, best))
        }
        if let best = paths.map(\.confidence).max() {
            candidates.append((.filePath, best))
        }
        if let best = code.map(\.confidence).max() {
            candidates.append((.code, best))
        }
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
                    "confidence": d.confidence
                ]
                if let ext = d.fileExtension { obj["extension"] = ext }
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
