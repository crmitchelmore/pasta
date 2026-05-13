import Foundation

public struct UUIDDetector {
    public struct Detection: Equatable {
        public var uuid: String
        public var version: Int?
        public var variant: String
        public var confidence: Double

        public init(uuid: String, version: Int?, variant: String, confidence: Double) {
            self.uuid = uuid
            self.version = version
            self.variant = variant
            self.confidence = confidence
        }
    }

    public init() {}

    /// Compiled once and reused — saves repeated ICU regex compilation.
    private static let regex: NSRegularExpression? = {
        let pattern = #"(?i)(?<![0-9a-f])([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f])"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    public func detect(in text: String) -> [Detection] {
        guard let regex = Self.regex else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Detection] = []
        results.reserveCapacity(matches.count)

        var seen = Set<String>()
        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[r]).lowercased()
            guard seen.insert(raw).inserted else { continue }

            let version = uuidVersion(from: raw)
            let variant = uuidVariant(from: raw)

            results.append(
                Detection(
                    uuid: raw,
                    version: version,
                    variant: variant,
                    confidence: 0.9
                )
            )
        }

        return results
    }

    /// UUID layout is fixed: positions 14 and 19 in the canonical
    /// 8-4-4-4-12 hyphenated form encode version and variant respectively.
    /// We index directly into the UTF-8 buffer (all ASCII) instead of
    /// allocating a `[Character]` per call.
    private func uuidVersion(from uuid: String) -> Int? {
        let utf8 = uuid.utf8
        guard utf8.count >= 15 else { return nil }
        let byte = utf8[utf8.index(utf8.startIndex, offsetBy: 14)]
        return Self.hexValue(byte)
    }

    private func uuidVariant(from uuid: String) -> String {
        let utf8 = uuid.utf8
        guard utf8.count >= 20 else { return "unknown" }
        let byte = utf8[utf8.index(utf8.startIndex, offsetBy: 19)]
        guard let value = Self.hexValue(byte) else { return "unknown" }

        switch value {
        case 0x0...0x7: return "ncs"
        case 0x8...0xb: return "rfc4122"
        case 0xc...0xd: return "microsoft"
        default: return "future"
        }
    }

    /// Branchless ASCII hex digit → integer. Returns nil for non-hex bytes.
    @inline(__always)
    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)            // '0'-'9'
        case 0x41...0x46: return Int(byte - 0x41 + 10)        // 'A'-'F'
        case 0x61...0x66: return Int(byte - 0x61 + 10)        // 'a'-'f'
        default: return nil
        }
    }
}
