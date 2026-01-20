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

    public func detect(in text: String) -> [Detection] {
        let pattern = #"(?i)(?<![0-9a-f])([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

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

    private func uuidVersion(from uuid: String) -> Int? {
        let chars = Array(uuid)
        guard chars.count >= 15 else { return nil }
        let versionChar = chars[14]
        return Int(String(versionChar), radix: 16)
    }

    private func uuidVariant(from uuid: String) -> String {
        let chars = Array(uuid)
        guard chars.count >= 20 else { return "unknown" }
        let variantChar = chars[19]
        guard let value = Int(String(variantChar), radix: 16) else { return "unknown" }

        switch value {
        case 0x0...0x7: return "ncs"
        case 0x8...0xb: return "rfc4122"
        case 0xc...0xd: return "microsoft"
        default: return "future"
        }
    }
}
