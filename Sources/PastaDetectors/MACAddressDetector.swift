import Foundation

public struct MACAddressDetector {
    public struct Detection: Equatable {
        public var raw: String
        public var normalized: String
        public var isMulticast: Bool
        public var isLocallyAdministered: Bool
        public var confidence: Double

        public init(
            raw: String,
            normalized: String,
            isMulticast: Bool,
            isLocallyAdministered: Bool,
            confidence: Double
        ) {
            self.raw = raw
            self.normalized = normalized
            self.isMulticast = isMulticast
            self.isLocallyAdministered = isLocallyAdministered
            self.confidence = confidence
        }
    }

    public enum Format: String, CaseIterable, Sendable {
        case colon
        case dash
        case cisco
    }

    public init() {}

    public static func builtInPatterns(for strictness: DetectorStrictness) -> [String] {
        switch strictness {
        case .strict:
            return [colonPattern]
        case .medium:
            return [colonPattern, dashPattern]
        case .lax:
            return [colonPattern, dashPattern, ciscoPattern]
        }
    }

    private static let colonPattern = #"(?i)(?<![0-9A-F:])([0-9A-F]{2}(?::[0-9A-F]{2}){5})(?![0-9A-F:])"#
    private static let dashPattern  = #"(?i)(?<![0-9A-F\-])([0-9A-F]{2}(?:-[0-9A-F]{2}){5})(?![0-9A-F\-])"#
    private static let ciscoPattern = #"(?i)(?<![0-9A-F\.])([0-9A-F]{4}(?:\.[0-9A-F]{4}){2})(?![0-9A-F\.])"#

    public func detect(
        in text: String,
        strictness: DetectorStrictness = .medium,
        advancedPatterns: [String] = []
    ) -> [Detection] {
        let patterns: [String]
        let usingAdvanced = !advancedPatterns.isEmpty
        if usingAdvanced {
            patterns = advancedPatterns
        } else {
            patterns = Self.builtInPatterns(for: strictness)
        }

        var seen = Set<String>()
        var out: [Detection] = []

        for pattern in patterns {
            for raw in RegexMatching.matches(pattern: pattern, in: text) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let normalized = Self.normalize(trimmed) else { continue }
                guard seen.insert(normalized).inserted else { continue }

                let firstByte = Self.firstByte(of: normalized) ?? 0
                let confidence: Double
                if usingAdvanced {
                    confidence = 0.85
                } else {
                    switch Self.format(of: trimmed) {
                    case .colon: confidence = 0.95
                    case .dash: confidence = 0.9
                    case .cisco: confidence = 0.8
                    }
                }

                out.append(
                    Detection(
                        raw: trimmed,
                        normalized: normalized,
                        isMulticast: (firstByte & 0x01) != 0,
                        isLocallyAdministered: (firstByte & 0x02) != 0,
                        confidence: confidence
                    )
                )
            }
        }

        return out
    }

    /// Returns digits in canonical uppercase colon-separated form, or nil if invalid.
    public static func normalize(_ raw: String) -> String? {
        let hex = raw.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        let chars = Array(hex)
        var pairs: [String] = []
        pairs.reserveCapacity(6)
        var i = 0
        while i < 12 {
            pairs.append(String(chars[i]) + String(chars[i + 1]))
            i += 2
        }
        return pairs.joined(separator: ":")
    }

    private static func firstByte(of normalized: String) -> UInt8? {
        let prefix = normalized.prefix(2)
        return UInt8(prefix, radix: 16)
    }

    private static func format(of raw: String) -> Format {
        if raw.contains(":") { return .colon }
        if raw.contains(".") { return .cisco }
        return .dash
    }
}
