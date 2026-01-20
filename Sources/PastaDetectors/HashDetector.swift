import Foundation

public struct HashDetector {
    public struct Detection: Equatable {
        public var hash: String
        public var kind: String
        public var bitLength: Int
        public var confidence: Double

        public init(hash: String, kind: String, bitLength: Int, confidence: Double) {
            self.hash = hash
            self.kind = kind
            self.bitLength = bitLength
            self.confidence = confidence
        }
    }

    public init() {}

    public func detect(in text: String) -> [Detection] {
        var detections: [Detection] = []
        detections.reserveCapacity(4)

        detections.append(contentsOf: detectHex(in: text))
        detections.append(contentsOf: detectBase64(in: text))

        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(detections.count)
        for d in detections {
            let key = d.hash.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(d)
        }

        return out
    }

    private func detectHex(in text: String) -> [Detection] {
        let pattern = #"(?i)(?<![0-9a-f])([0-9a-f]{32}|[0-9a-f]{40}|[0-9a-f]{56}|[0-9a-f]{64}|[0-9a-f]{96}|[0-9a-f]{128})(?![0-9a-f])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Detection] = []
        results.reserveCapacity(matches.count)

        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let hash = String(text[r]).lowercased()
            guard let bitLength = hexBitLength(for: hash.count) else { continue }
            let kind = hexKind(for: hash.count)
            results.append(Detection(hash: hash, kind: kind, bitLength: bitLength, confidence: 0.85))
        }

        return results
    }

    private func detectBase64(in text: String) -> [Detection] {
        let pattern = #"(?<![A-Za-z0-9+/=])([A-Za-z0-9+/]{43}={0,2}|[A-Za-z0-9+/]{86}={0,2}|[A-Za-z0-9+/]{128}={0,2}|[A-Za-z0-9+/]{171}={0,2})(?![A-Za-z0-9+/=])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Detection] = []
        results.reserveCapacity(matches.count)

        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let hash = String(text[r])
            let kind = base64Kind(for: hash.count)
            let bits = base64BitLength(for: hash.count)
            results.append(Detection(hash: hash, kind: kind, bitLength: bits, confidence: 0.75))
        }

        return results
    }

    private func hexKind(for length: Int) -> String {
        switch length {
        case 32: return "md5"
        case 40: return "sha1"
        case 56: return "sha224"
        case 64: return "sha256"
        case 96: return "sha384"
        case 128: return "sha512"
        default: return "hash"
        }
    }

    private func hexBitLength(for length: Int) -> Int? {
        switch length {
        case 32: return 128
        case 40: return 160
        case 56: return 224
        case 64: return 256
        case 96: return 384
        case 128: return 512
        default: return nil
        }
    }

    private func base64Kind(for length: Int) -> String {
        switch length {
        case 43, 44: return "sha256"
        case 86, 88: return "sha512"
        case 128: return "sha768"
        case 171, 172: return "sha1024"
        default: return "hash"
        }
    }

    private func base64BitLength(for length: Int) -> Int {
        switch length {
        case 43, 44: return 256
        case 86, 88: return 512
        case 128: return 768
        case 171, 172: return 1024
        default: return length * 6
        }
    }
}
