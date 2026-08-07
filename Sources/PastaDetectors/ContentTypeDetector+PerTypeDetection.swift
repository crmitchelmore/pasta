import Foundation
import PastaCore

extension ContentTypeDetector {
    func detectorRule(for detector: BuiltInDetectorKind, configuration: DetectorConfiguration) -> DetectorRuleConfig {
        configuration.rule(for: detector)
    }

    func detectorStrictness(for detector: BuiltInDetectorKind, configuration: DetectorConfiguration) -> DetectorStrictness {
        configuration.strictness(for: detector)
    }

    func detectEmails(in text: String, configuration: DetectorConfiguration) -> [EmailDetector.Detection] {
        let rule = detectorRule(for: .email, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map {
                EmailDetector.Detection(email: $0.lowercased(), confidence: 0.9)
            }
        }

        let detected = emailDetector.detect(in: text)
        switch detectorStrictness(for: .email, configuration: configuration) {
        case .strict:
            return detected.filter { detection in
                let parts = detection.email.split(separator: "@")
                guard parts.count == 2 else { return false }
                let labels = parts[1].split(separator: ".")
                guard labels.count >= 2, let tld = labels.last else { return false }
                return tld.count >= 2
            }
        case .medium, .lax:
            return detected
        }
    }

    func detectPhoneNumbers(in text: String, configuration: DetectorConfiguration) -> [PhoneNumberDetector.Detection] {
        let rule = detectorRule(for: .phoneNumber, configuration: configuration)
        guard rule.isEnabled else { return [] }
        return phoneNumberDetector.detect(
            in: text,
            strictness: detectorStrictness(for: .phoneNumber, configuration: configuration),
            advancedPatterns: rule.useAdvancedPatterns ? rule.cleanedPatterns : []
        )
    }

    func detectIPAddresses(in text: String, configuration: DetectorConfiguration) -> [IPAddressDetector.Detection] {
        let rule = detectorRule(for: .ipAddress, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { candidate in
                let lower = candidate.lowercased()
                let isV4 = candidate.contains(".")
                return IPAddressDetector.Detection(
                    address: candidate,
                    version: isV4 ? "v4" : "v6",
                    isPrivate: lower.hasPrefix("10.") || lower.hasPrefix("192.168.") || lower.hasPrefix("172."),
                    isLoopback: lower == "127.0.0.1" || lower == "::1",
                    isLinkLocal: lower.hasPrefix("169.254.") || lower.hasPrefix("fe80:"),
                    isMulticast: lower.hasPrefix("224.") || lower.hasPrefix("ff"),
                    confidence: 0.85
                )
            }
        }

        let detected = ipAddressDetector.detect(in: text)
        switch detectorStrictness(for: .ipAddress, configuration: configuration) {
        case .strict:
            return detected.filter { !$0.isPrivate && !$0.isLoopback && !$0.isLinkLocal }
        case .medium, .lax:
            return detected
        }
    }

    func detectUUIDs(in text: String, configuration: DetectorConfiguration) -> [UUIDDetector.Detection] {
        let rule = detectorRule(for: .uuid, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { candidate in
                UUIDDetector.Detection(uuid: candidate.lowercased(), version: nil, variant: "custom", confidence: 0.85)
            }
        }

        let detected = uuidDetector.detect(in: text)
        switch detectorStrictness(for: .uuid, configuration: configuration) {
        case .strict:
            return detected.filter { ($0.version ?? 0) > 0 && ($0.version ?? 0) <= 8 && $0.variant == "rfc4122" }
        case .medium, .lax:
            return detected
        }
    }

    func detectHashes(in text: String, configuration: DetectorConfiguration) -> [HashDetector.Detection] {
        let rule = detectorRule(for: .hash, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { candidate in
                HashDetector.Detection(hash: candidate, kind: "custom", bitLength: candidate.count * 4, confidence: 0.8)
            }
        }

        let detected = hashDetector.detect(in: text)
        switch detectorStrictness(for: .hash, configuration: configuration) {
        case .strict:
            return detected.filter { $0.bitLength >= 224 && $0.kind != "md5" && $0.kind != "sha1" }
        case .medium, .lax:
            return detected
        }
    }

    func detectJWT(in text: String, configuration: DetectorConfiguration) -> [JWTDetector.Detection] {
        let rule = detectorRule(for: .jwt, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { token in
                JWTDetector.Detection(
                    token: token,
                    confidence: 0.75,
                    headerJSON: "{}",
                    payloadJSON: "{}",
                    claims: JWTDetector.Claims(),
                    isExpired: nil
                )
            }
        }

        let detected = jwtDetector.detect(in: text)
        switch detectorStrictness(for: .jwt, configuration: configuration) {
        case .strict:
            return detected.filter { $0.isExpired != true }
        case .medium, .lax:
            return detected
        }
    }

    func detectAPIKeys(in text: String, configuration: DetectorConfiguration) -> [APIKeyDetector.Detection] {
        let rule = detectorRule(for: .apiKey, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { key in
                APIKeyDetector.Detection(key: key, provider: "Custom", confidence: 0.75, isLikelyLive: true)
            }
        }

        let detected = apiKeyDetector.detect(in: text)
        switch detectorStrictness(for: .apiKey, configuration: configuration) {
        case .strict:
            return detected.filter { $0.confidence >= 0.85 && $0.isLikelyLive }
        case .medium:
            return detected.filter { $0.confidence >= 0.7 }
        case .lax:
            return detected.filter { $0.confidence >= 0.5 }
        }
    }

    func detectEnvVars(in text: String, configuration: DetectorConfiguration) -> EnvVarDetector.Output? {
        let rule = detectorRule(for: .envVar, configuration: configuration)
        guard rule.isEnabled else { return nil }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            let matches = matchPatterns(rule.cleanedPatterns, in: text)
            guard !matches.isEmpty else { return nil }
            let detections = matches.map {
                EnvVarDetector.Detection(key: "CUSTOM", value: $0, isExported: false, confidence: 0.75)
            }
            return EnvVarDetector.Output(detections: detections, isBlock: detections.count >= 2)
        }

        let detected = envVarDetector.detect(in: text)
        switch detectorStrictness(for: .envVar, configuration: configuration) {
        case .strict:
            guard let detected else { return nil }
            let filtered = detected.detections.filter { detection in
                detection.key == detection.key.uppercased()
            }
            guard !filtered.isEmpty else { return nil }
            return EnvVarDetector.Output(detections: filtered, isBlock: filtered.count >= 2)
        case .medium, .lax:
            return detected
        }
    }

    func detectURLs(in text: String, configuration: DetectorConfiguration) -> [URLDetector.Detection] {
        let rule = detectorRule(for: .url, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).compactMap { candidate in
                guard let url = URL(string: candidate), let host = url.host else { return nil }
                return URLDetector.Detection(
                    url: url.absoluteString,
                    domain: host,
                    category: "custom",
                    confidence: 0.85,
                    hotCount: 1
                )
            }
        }

        let detected = urlDetector.detect(in: text)
        switch detectorStrictness(for: .url, configuration: configuration) {
        case .strict:
            return detected.filter { detection in
                guard let parsed = URL(string: detection.url), let host = parsed.host else { return false }
                return parsed.scheme?.lowercased() == "https" && host.contains(".")
            }
        case .medium, .lax:
            return detected
        }
    }

    func detectFilePaths(in text: String, configuration: DetectorConfiguration) -> [FilePathDetector.Detection] {
        let rule = detectorRule(for: .filePath, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { path in
                FilePathDetector.Detection(
                    path: path,
                    exists: false,
                    filename: URL(fileURLWithPath: path).lastPathComponent,
                    fileExtension: URL(fileURLWithPath: path).pathExtension,
                    fileType: .other,
                    mimeType: nil,
                    confidence: 0.75
                )
            }
        }

        let detected = filePathDetector.detect(in: text)
        switch detectorStrictness(for: .filePath, configuration: configuration) {
        case .strict:
            return detected.filter(\.exists)
        case .medium, .lax:
            return detected
        }
    }

    func detectShellCommands(in text: String, configuration: DetectorConfiguration) -> [ShellCommandDetector.Detection] {
        let rule = detectorRule(for: .shellCommand, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            return matchPatterns(rule.cleanedPatterns, in: text).map { command in
                let executable = command.split(separator: " ").first.map(String.init) ?? command
                return ShellCommandDetector.Detection(command: command, executable: executable, confidence: 0.75)
            }
        }

        let detected = shellCommandDetector.detect(in: text)
        switch detectorStrictness(for: .shellCommand, configuration: configuration) {
        case .strict:
            return detected.filter { $0.confidence >= 0.7 }
        case .medium:
            return detected.filter { $0.confidence >= 0.5 }
        case .lax:
            return detected.filter { $0.confidence >= 0.4 }
        }
    }

    func detectColors(in text: String, configuration: DetectorConfiguration) -> [ColorDetector.Detection] {
        let rule = detectorRule(for: .color, configuration: configuration)
        guard rule.isEnabled else { return [] }

        if rule.useAdvancedPatterns, !rule.cleanedPatterns.isEmpty {
            let candidates = matchPatterns(rule.cleanedPatterns, in: text)
            var out: [ColorDetector.Detection] = []
            var seen = Set<String>()
            for cand in candidates {
                let parsed = colorDetector.detect(in: cand, namedColorPolicy: .wholeStringOnly)
                for det in parsed where seen.insert(det.raw.lowercased()).inserted {
                    out.append(det)
                }
            }
            return out
        }

        let strictness = detectorStrictness(for: .color, configuration: configuration)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch strictness {
        case .strict:
            let candidates = colorDetector.detect(in: trimmed, namedColorPolicy: .wholeStringOnly)
            return candidates.filter { det in
                det.raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == trimmed.lowercased()
            }
        case .medium:
            return colorDetector.detect(in: text, namedColorPolicy: .wholeStringOnly)
        case .lax:
            return colorDetector.detect(in: text, namedColorPolicy: .extract)
        }
    }

    func detectMACAddresses(in text: String, configuration: DetectorConfiguration) -> [MACAddressDetector.Detection] {
        let rule = detectorRule(for: .macAddress, configuration: configuration)
        guard rule.isEnabled else { return [] }
        return macAddressDetector.detect(
            in: text,
            strictness: detectorStrictness(for: .macAddress, configuration: configuration),
            advancedPatterns: rule.useAdvancedPatterns ? rule.cleanedPatterns : []
        )
    }

    func detectCreditCards(in text: String, configuration: DetectorConfiguration) -> [CreditCardDetector.Detection] {
        let rule = detectorRule(for: .creditCard, configuration: configuration)
        guard rule.isEnabled else { return [] }
        return creditCardDetector.detect(
            in: text,
            strictness: detectorStrictness(for: .creditCard, configuration: configuration),
            advancedPatterns: rule.useAdvancedPatterns ? rule.cleanedPatterns : []
        )
    }

    func detectIBANs(in text: String, configuration: DetectorConfiguration) -> [IBANDetector.Detection] {
        let rule = detectorRule(for: .iban, configuration: configuration)
        guard rule.isEnabled else { return [] }
        return ibanDetector.detect(
            in: text,
            strictness: detectorStrictness(for: .iban, configuration: configuration),
            advancedPatterns: rule.useAdvancedPatterns ? rule.cleanedPatterns : []
        )
    }

    func detectCustomDetections(in text: String, configuration: DetectorConfiguration) -> [CustomDetection] {
        let active = configuration.customDetectors.filter { $0.isEnabled }
        guard !active.isEmpty else { return [] }

        var out: [CustomDetection] = []
        out.reserveCapacity(16)
        var seen = Set<String>()

        for detector in active {
            let options: NSRegularExpression.Options = detector.isCaseInsensitive ? [.caseInsensitive] : []
            let matches = matchPatterns([detector.pattern], in: text, options: options)
            for value in matches {
                let key = "\(detector.id.uuidString)|\(value)"
                guard seen.insert(key).inserted else { continue }
                out.append(CustomDetection(name: detector.name, value: value, confidence: detector.confidence))
            }
        }

        return out
    }

    static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 256
        return cache
    }()

    func matchPatterns(
        _ patterns: [String],
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        let clamped = text.count > Self.maxAnalysisLength ? String(text.prefix(Self.maxAnalysisLength)) : text
        let range = NSRange(clamped.startIndex..<clamped.endIndex, in: clamped)

        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(16)

        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let cacheKey = NSString(string: "\(options.rawValue)::\(trimmed)")
            let regex: NSRegularExpression
            if let cached = Self.regexCache.object(forKey: cacheKey) {
                regex = cached
            } else {
                guard let compiled = try? NSRegularExpression(pattern: trimmed, options: options) else { continue }
                Self.regexCache.setObject(compiled, forKey: cacheKey)
                regex = compiled
            }

            let matches = regex.matches(in: clamped, options: [], range: range)
            for match in matches {
                let selectedRange: NSRange
                if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    selectedRange = match.range(at: 1)
                } else {
                    selectedRange = match.range(at: 0)
                }
                guard let valueRange = Range(selectedRange, in: clamped) else { continue }
                let value = String(clamped[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                guard seen.insert(value).inserted else { continue }
                out.append(value)
            }
        }

        return out
    }
}
