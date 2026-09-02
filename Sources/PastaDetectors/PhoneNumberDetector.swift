import Foundation

public struct PhoneNumberDetector {
    public struct Detection: Equatable {
        public var phoneNumber: String
        public var confidence: Double

        public init(phoneNumber: String, confidence: Double) {
            self.phoneNumber = phoneNumber
            self.confidence = confidence
        }
    }

    public init() {}

    public static func builtInPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return PatternSet.strict
        case .medium:
            return PatternSet.medium
        case .lax:
            return PatternSet.lax
        }
    }

    private enum PatternSet {
        static let strict: [String] = [
            #"(?<!\d)(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.-]\d{3,4}[\s.-]\d{3,4}(?!\d)"#,
            #"(?<!\d)\+\d{1,3}[\s.-]\d{1,4}[\s.-]\d{3,4}[\s.-]\d{3,4}(?!\d)"#
        ]

        static let medium: [String] = [
            #"(?<!\d)(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.-]?\d{3,4}[\s.-]\d{3,4}(?!\d)"#,
            #"(?<!\d)\+\d{1,3}[\s.-]?\d{6,12}(?!\d)"#
        ]

        static let lax: [String] = [
            #"(?<!\d)\+?\d(?:[().\-\s]?\d){6,17}(?!\d)"#
        ]
    }

    public func detect(
        in text: String,
        strictness: DetectorStrictness = .medium,
        advancedPatterns: [String] = []
    ) -> [Detection] {
        let candidatePatterns: [String]
        let usesAdvancedPatterns = !advancedPatterns.isEmpty
        if usesAdvancedPatterns {
            candidatePatterns = advancedPatterns
        } else {
            candidatePatterns = Self.builtInPatterns(for: strictness)
        }

        var candidates: [String] = []
        candidates.reserveCapacity(16)
        for pattern in candidatePatterns {
            candidates.append(contentsOf: RegexMatching.matches(pattern: pattern, in: text))
        }

        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(candidates.count)
        for candidate in candidates {
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if usesAdvancedPatterns {
                guard cleaned.count >= 3 else { continue }
            } else {
                guard isValidPhone(cleaned, strictness: strictness) else { continue }
            }

            let dedupeKey = normalizedForDedupe(cleaned)
            guard seen.insert(dedupeKey).inserted else { continue }

            let confidence: Double
            if usesAdvancedPatterns {
                confidence = 0.85
            } else {
                switch strictness {
                case .strict: confidence = 0.95
                case .medium: confidence = 0.9
                case .lax: confidence = 0.75
                }
            }
            out.append(Detection(phoneNumber: cleaned, confidence: confidence))
        }

        return out
    }


    private func normalizedForDedupe(_ value: String) -> String {
        var digits = value.filter(\.isNumber)
        if value.trimmingCharacters(in: .whitespaces).hasPrefix("+") {
            digits = "+" + digits
        }
        return digits
    }

    private func isValidPhone(_ value: String, strictness: DetectorStrictness) -> Bool {
        let digits = value.filter(\.isNumber).count
        let separatorCount = value.filter { " -().".contains($0) }.count

        switch strictness {
        case .strict:
            return digits >= 10 && digits <= 15 && separatorCount >= 2
        case .medium:
            return digits >= 8 && digits <= 15 && separatorCount >= 1
        case .lax:
            return digits >= 7 && digits <= 18
        }
    }
}
