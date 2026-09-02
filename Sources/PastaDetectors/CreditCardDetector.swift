import Foundation

public struct CreditCardDetector {
    public struct Detection: Equatable {
        public var raw: String
        public var normalized: String
        public var maskedDisplay: String
        public var brand: String
        public var last4: String
        public var confidence: Double

        public init(
            raw: String,
            normalized: String,
            maskedDisplay: String,
            brand: String,
            last4: String,
            confidence: Double
        ) {
            self.raw = raw
            self.normalized = normalized
            self.maskedDisplay = maskedDisplay
            self.brand = brand
            self.last4 = last4
            self.confidence = confidence
        }
    }

    public init() {}

    public static func builtInPatterns(for strictness: DetectorStrictness) -> [String] {
        // Same regex shape across strictness — semantic filtering happens after Luhn.
        return [
            #"(?<!\d)((?:\d[ \-]?){12,18}\d)(?!\d)"#
        ]
    }

    private static let knownBrands: Set<String> = ["Visa", "Mastercard", "Amex", "Discover"]
    private static let validLengths: Set<Int> = [13, 15, 16, 19]

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
                let digits = trimmed.filter(\.isNumber)
                guard digits.count >= 13, digits.count <= 19 else { continue }
                guard Self.luhnIsValid(digits) else { continue }
                guard seen.insert(digits).inserted else { continue }

                let brand = Self.brand(for: digits)

                if strictness == .strict {
                    guard Self.knownBrands.contains(brand),
                          Self.validLengths.contains(digits.count)
                    else { continue }
                }

                let confidence: Double = brand == "Other" ? 0.7 : 0.9
                out.append(
                    Detection(
                        raw: trimmed,
                        normalized: digits,
                        maskedDisplay: Self.mask(digits),
                        brand: brand,
                        last4: String(digits.suffix(4)),
                        confidence: confidence
                    )
                )
            }
        }

        return out
    }

    /// Validate digits via Luhn / mod-10 checksum.
    public static func luhnIsValid(_ digits: String) -> Bool {
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        var alternate = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            if alternate {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    /// Brand classification using IIN / length heuristics.
    public static func brand(for digits: String) -> String {
        let length = digits.count
        let chars = Array(digits)
        guard chars.count >= 2 else { return "Other" }

        let first1 = Int(String(chars[0])) ?? 0
        let first2 = Int(String(chars.prefix(2))) ?? 0
        let first3 = chars.count >= 3 ? (Int(String(chars.prefix(3))) ?? 0) : 0
        let first4 = chars.count >= 4 ? (Int(String(chars.prefix(4))) ?? 0) : 0
        let first6 = chars.count >= 6 ? (Int(String(chars.prefix(6))) ?? 0) : 0

        // Visa: starts with 4, length 13/16/19
        if first1 == 4, [13, 16, 19].contains(length) {
            return "Visa"
        }
        // Amex: starts with 34/37, length 15
        if (first2 == 34 || first2 == 37), length == 15 {
            return "Amex"
        }
        // Mastercard: 51-55 (length 16) or 2221-2720 (length 16)
        if length == 16 {
            if first2 >= 51 && first2 <= 55 {
                return "Mastercard"
            }
            if first4 >= 2221 && first4 <= 2720 {
                return "Mastercard"
            }
        }
        // Discover: 6011, 65, 644-649, 622126-622925; length 16 or 19
        if length == 16 || length == 19 {
            if first4 == 6011 || first2 == 65 {
                return "Discover"
            }
            if first3 >= 644 && first3 <= 649 {
                return "Discover"
            }
            if first6 >= 622126 && first6 <= 622925 {
                return "Discover"
            }
        }
        return "Other"
    }

    /// Produces a "**** **** **** 1234" style mask.
    public static func mask(_ digits: String) -> String {
        guard digits.count >= 4 else { return String(repeating: "*", count: digits.count) }
        let last4 = String(digits.suffix(4))
        let hidden = digits.count - 4
        let masked = String(repeating: "*", count: hidden) + last4
        var grouped = ""
        for (i, ch) in masked.enumerated() {
            if i > 0 && i % 4 == 0 { grouped.append(" ") }
            grouped.append(ch)
        }
        return grouped
    }
}
