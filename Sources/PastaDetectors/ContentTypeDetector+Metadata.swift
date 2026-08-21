import Foundation
import PastaCore

extension ContentTypeDetector {
    /// Builds the per-detector split entries when env-var blocks are detected.
    func makeSplitEntries(envOutput: EnvVarDetector.Output?) -> [SplitEntry] {
        guard let envOutput, envOutput.isBlock else { return [] }

        return envOutput.detections.map { d in
            let content = d.isExported ? "export \(d.key)=\(d.value)" : "\(d.key)=\(d.value)"
            let meta: [String: Any] = ["key": d.key, "isExported": d.isExported]
            return SplitEntry(content: content, contentType: .envVar, metadataJSON: jsonString(meta))
        }
    }

    /// Extracts individual items from mixed content.
    /// Only extracts when content is prose/text with multiple detectable items embedded.
    func makeExtractedItems(
        primaryType: ContentType,
        analysisText: String,
        emails: [EmailDetector.Detection],
        urls: [URLDetector.Detection],
        apiKeys: [APIKeyDetector.Detection],
        phoneNumbers: [PhoneNumberDetector.Detection],
        ipAddresses: [IPAddressDetector.Detection],
        uuids: [UUIDDetector.Detection],
        paths: [FilePathDetector.Detection],
        customDetections: [CustomDetection]
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
        let totalItems = emails.count + urls.count + apiKeys.count + phoneNumbers.count + ipAddresses.count + uuids.count + paths.count + customDetections.count

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
            var pathMeta: [String: Any] = [
                "path": path.path,
                "filename": path.filename,
                "fileExtension": path.fileExtension ?? "",
                "fileType": path.fileType.rawValue,
                "confidence": path.confidence
            ]
            // Persist only real filesystem answers; a path beyond the
            // existence-check budget must not be stored as "missing".
            if let exists = path.exists {
                pathMeta["exists"] = exists
            }
            let meta = jsonString(pathMeta)
            items.append(SplitEntry(content: path.path, contentType: .filePath, metadataJSON: meta))
        }

        for detection in customDetections.prefix(maxItems - items.count) {
            let meta = jsonString([
                "name": detection.name,
                "value": detection.value,
                "confidence": detection.confidence
            ])
            items.append(
                SplitEntry(
                    content: detection.value,
                    contentType: .text,
                    metadataJSON: meta
                )
            )
        }

        return items
    }

    func buildMetadataJSON(
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
        prose: ProseDetector.Detection?,
        colors: [ColorDetector.Detection],
        macAddresses: [MACAddressDetector.Detection],
        creditCards: [CreditCardDetector.Detection],
        ibans: [IBANDetector.Detection],
        customDetections: [CustomDetection]
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
                    "filename": d.filename,
                    "fileType": d.fileType.rawValue,
                    "confidence": d.confidence
                ]
                // Only persist real filesystem answers — a path beyond the
                // existence-check budget must not be stored as "missing".
                if let exists = d.exists { obj["exists"] = exists }
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

        if !macAddresses.isEmpty {
            meta["macAddresses"] = macAddresses.map { d in
                [
                    "raw": d.raw,
                    "normalized": d.normalized,
                    "isMulticast": d.isMulticast,
                    "isLocallyAdministered": d.isLocallyAdministered,
                    "confidence": d.confidence
                ] as [String: Any]
            }
        }

        if !creditCards.isEmpty {
            // Important: only store masked form + last4, NOT the full PAN.
            meta["creditCards"] = creditCards.map { d in
                [
                    "masked": d.maskedDisplay,
                    "last4": d.last4,
                    "brand": d.brand,
                    "confidence": d.confidence
                ] as [String: Any]
            }
        }

        if !ibans.isEmpty {
            meta["ibans"] = ibans.map { d in
                [
                    "iban": d.normalized,
                    "country": d.countryCode,
                    "confidence": d.confidence
                ] as [String: Any]
            }
        }

        if !customDetections.isEmpty {
            meta["customDetectors"] = customDetections.map { detection in
                [
                    "name": detection.name,
                    "value": detection.value,
                    "confidence": detection.confidence
                ]
            }
        }

        if !colors.isEmpty {
            meta["colors"] = colors.map { detection in
                [
                    "raw": detection.raw,
                    "format": detection.format.rawValue,
                    "red": Int(detection.red),
                    "green": Int(detection.green),
                    "blue": Int(detection.blue),
                    "alpha": detection.alpha,
                    "confidence": detection.confidence
                ] as [String: Any]
            }
        }

        return jsonString(meta)
    }

    func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
