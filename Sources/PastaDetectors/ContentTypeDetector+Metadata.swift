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
    /// The primary classification must not suppress embedded values.
    func makeExtractedItems(
        analysisText: String,
        emails: [EmailDetector.Detection],
        urls: [URLDetector.Detection],
        apiKeys: [APIKeyDetector.Detection],
        phoneNumbers: [PhoneNumberDetector.Detection],
        ipAddresses: [IPAddressDetector.Detection],
        uuids: [UUIDDetector.Detection],
        paths: [FilePathDetector.Detection],
        customDetections: [CustomDetection],
        additionalItems: [SplitEntry]
    ) -> [SplitEntry] {
        // Count total extractable items
        let totalItems = emails.count + urls.count + apiKeys.count + phoneNumbers.count + ipAddresses.count + uuids.count + paths.count + customDetections.count + additionalItems.count

        // Only extract if there are items to extract (and content isn't just one item)
        guard totalItems > 0 else {
            return []
        }

        var items: [SplitEntry] = []

        // Extract emails
        for email in emails {
            let meta = jsonString(["email": email.email, "confidence": email.confidence])
            items.append(SplitEntry(content: email.email, contentType: .email, metadataJSON: meta))
        }

        // Extract URLs
        for url in urls {
            let meta = jsonString(["url": url.url, "domain": url.domain, "category": url.category, "confidence": url.confidence])
            items.append(SplitEntry(content: url.url, contentType: .url, metadataJSON: meta))
        }

        // Extract API keys (high value)
        for apiKey in apiKeys where apiKey.confidence >= 0.7 {
            let meta = jsonString(["provider": apiKey.provider, "confidence": apiKey.confidence, "isLikelyLive": apiKey.isLikelyLive])
            items.append(SplitEntry(content: apiKey.key, contentType: .apiKey, metadataJSON: meta))
        }

        // Extract phone numbers
        for phone in phoneNumbers {
            let meta = jsonString(["number": phone.phoneNumber, "confidence": phone.confidence])
            items.append(SplitEntry(content: phone.phoneNumber, contentType: .phoneNumber, metadataJSON: meta))
        }

        // Include internal addresses accepted by the active detector rules.
        for ip in ipAddresses {
            let meta = jsonString(["address": ip.address, "version": ip.version, "confidence": ip.confidence])
            items.append(SplitEntry(content: ip.address, contentType: .ipAddress, metadataJSON: meta))
        }

        for uuid in uuids {
            let meta = jsonString(["uuid": uuid.uuid, "variant": uuid.variant, "confidence": uuid.confidence])
            items.append(SplitEntry(content: uuid.uuid, contentType: .uuid, metadataJSON: meta))
        }

        // Extract file paths
        for path in paths where !urls.contains(where: { $0.url.contains(path.path) }) {
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

        for detection in customDetections {
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

        items.append(contentsOf: additionalItems)
        let trimmed = analysisText.trimmingCharacters(in: .whitespacesAndNewlines)
        let containers: Set<ContentType> = [.text, .code, .shellCommand, .envVar, .envVarBlock]
        guard !items.contains(where: { $0.content == trimmed && !containers.contains($0.contentType) }) else { return [] }
        var seen: Set<String> = []
        return items.filter {
            $0.content != trimmed && seen.insert("\($0.contentType.rawValue):\($0.content)").inserted
        }
    }

    func makeAdditionalExtractedItems(analysisText: String, metadataJSON: String?) -> [SplitEntry] {
        guard let metadataJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any] else { return [] }
        let fields: [ContentType: (key: String, field: String)] = [
            .hash: ("hashes", "hash"), .jwt: ("jwt", "token"),
            .shellCommand: ("shellCommands", "command"), .code: ("code", "value"),
            .color: ("colors", "raw"), .macAddress: ("macAddresses", "raw"),
            .iban: ("ibans", "raw"), .creditCard: ("creditCards", "masked")
        ]
        var recordsByType: [ContentType: [String: [[String: Any]]]] = [:]
        for (type, field) in fields {
            for record in object[field.key] as? [[String: Any]] ?? [] {
                let value: String?
                if type == .code || type == .creditCard,
                   let location = record["location"] as? Int, let length = record["length"] as? Int,
                   let range = Range(NSRange(location: location, length: length), in: analysisText) {
                    value = String(analysisText[range])
                } else {
                    value = record[field.field] as? String
                }
                if let value {
                    recordsByType[type, default: [:]][value, default: []].append(record)
                }
            }
        }
        let env = object["env"] as? [String: Any]
        for record in env?["vars"] as? [[String: Any]] ?? [] {
            if let value = record["raw"] as? String {
                recordsByType[.envVar, default: [:]][value, default: []].append(record)
            }
        }
        let values = MetadataParser.extractAllValues(from: metadataJSON, content: analysisText)
        var items: [SplitEntry] = []
        for value in values {
            guard var records = recordsByType[value.type]?[value.value] else { continue }
            let metadata: [String: Any]
            if value.type == .envVar {
                metadata = ["env": ["isBlock": false, "vars": records]]
            } else if let field = fields[value.type] {
                if value.type == .creditCard || value.type == .code {
                    records = records.map {
                        var record = $0
                        record["location"] = 0
                        record["length"] = value.value.utf16.count
                        return record
                    }
                }
                metadata = [field.key: records]
            } else {
                continue
            }
            items.append(SplitEntry(content: value.value, contentType: value.type, metadataJSON: jsonString(metadata)))
        }
        if let env, env["isBlock"] as? Bool == true {
            let assignments = values.filter { $0.type == .envVar }.map(\.value).joined(separator: "\n")
            items.append(SplitEntry(content: assignments, contentType: .envVarBlock, metadataJSON: jsonString(["env": env])))
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
                "vars": env.detections.map { [
                    "key": $0.key, "value": $0.value, "isExported": $0.isExported, "confidence": $0.confidence,
                    "raw": $0.raw ?? ($0.isExported ? "export " : "") + "\($0.key)=\($0.value)"
                ] as [String: Any] }
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
            meta["code"] = code.map {
                var item: [String: Any] = ["language": $0.language.rawValue, "confidence": $0.confidence]
                if $0.code != analysisText.trimmingCharacters(in: .whitespacesAndNewlines),
                   let range = analysisText.range(of: $0.code) {
                    let span = NSRange(range, in: analysisText)
                    item["location"] = span.location
                    item["length"] = span.length
                }
                return item
            }
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
                var item: [String: Any] = [
                    "masked": d.maskedDisplay,
                    "last4": d.last4,
                    "brand": d.brand,
                    "confidence": d.confidence
                ]
                if let range = analysisText.range(of: d.raw) {
                    let span = NSRange(range, in: analysisText)
                    item["location"] = span.location
                    item["length"] = span.length
                }
                return item
            }
        }

        if !ibans.isEmpty {
            meta["ibans"] = ibans.map { d in
                [
                    "iban": d.normalized,
                    "raw": d.raw,
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
