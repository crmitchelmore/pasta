import Foundation

public struct IBANDetector {
    public struct Detection: Equatable {
        public var raw: String
        public var normalized: String
        public var countryCode: String
        public var confidence: Double

        public init(raw: String, normalized: String, countryCode: String, confidence: Double) {
            self.raw = raw
            self.normalized = normalized
            self.countryCode = countryCode
            self.confidence = confidence
        }
    }

    /// Common IBAN-using countries. Not exhaustive — used to gate strict mode.
    public static let knownCountries: Set<String> = [
        "AD","AE","AL","AT","AZ","BA","BE","BG","BH","BR","BY","CH","CR","CY","CZ",
        "DE","DK","DO","EE","EG","ES","FI","FO","FR","GB","GE","GI","GL","GR","GT",
        "HR","HU","IE","IL","IQ","IS","IT","JO","KW","KZ","LB","LC","LI","LT","LU",
        "LV","MC","MD","ME","MK","MR","MT","MU","NL","NO","PK","PL","PS","PT","QA",
        "RO","RS","SA","SC","SE","SI","SK","SM","ST","SV","TL","TN","TR","UA","VA",
        "VG","XK"
    ]

    public init() {}

    public static func builtInPatterns(for strictness: DetectorStrictness) -> [String] {
        return [
            #"(?i)(?<![A-Z0-9])([A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30})(?![A-Z0-9])"#
        ]
    }

    public func detect(
        in text: String,
        strictness: DetectorStrictness = .medium,
        advancedPatterns: [String] = []
    ) -> [Detection] {
        let patterns: [String]
        if !advancedPatterns.isEmpty {
            patterns = advancedPatterns
        } else {
            patterns = Self.builtInPatterns(for: strictness)
        }

        var seen = Set<String>()
        var out: [Detection] = []

        for pattern in patterns {
            for raw in RegexMatching.matches(pattern: pattern, in: text) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.uppercased().filter { $0.isLetter || $0.isNumber }
                guard normalized.count >= 15, normalized.count <= 34 else { continue }
                guard Self.mod97IsValid(normalized) else { continue }
                guard seen.insert(normalized).inserted else { continue }

                let country = String(normalized.prefix(2))

                if strictness == .strict, !Self.knownCountries.contains(country) {
                    continue
                }

                let confidence: Double = Self.knownCountries.contains(country) ? 0.95 : 0.8
                out.append(
                    Detection(
                        raw: trimmed,
                        normalized: normalized,
                        countryCode: country,
                        confidence: confidence
                    )
                )
            }
        }

        return out
    }

    /// Mod-97 IBAN check. Input must be the normalized (no spaces, uppercased) IBAN.
    public static func mod97IsValid(_ iban: String) -> Bool {
        guard iban.count >= 15, iban.count <= 34 else { return false }
        // Move the first 4 characters to the end.
        let head = iban.prefix(4)
        let tail = iban.dropFirst(4)
        let rearranged = String(tail) + String(head)

        // Convert letters: A=10, B=11, ..., Z=35.
        var converted = ""
        converted.reserveCapacity(rearranged.count * 2)
        for ch in rearranged {
            if ch.isLetter, let scalar = ch.asciiValue {
                let value = Int(scalar) - 55  // 'A' is 65 -> 10
                guard value >= 10, value <= 35 else { return false }
                converted.append(String(value))
            } else if ch.isNumber {
                converted.append(ch)
            } else {
                return false
            }
        }

        // Compute mod-97 in chunks (numbers can be hundreds of digits).
        var remainder = 0
        var index = converted.startIndex
        while index < converted.endIndex {
            let next = converted.index(index, offsetBy: 9, limitedBy: converted.endIndex) ?? converted.endIndex
            let chunkStr = String(remainder) + String(converted[index..<next])
            guard let chunk = Int(chunkStr) else { return false }
            remainder = chunk % 97
            index = next
        }
        return remainder == 1
    }
}
