import Foundation

public struct EncodingDetector {
    public struct Detection: Equatable {
        public enum Encoding: String, Equatable {
            case base64
            case url
        }

        public struct Step: Equatable {
            public var encoding: Encoding
            public var before: String
            public var after: String

            public init(encoding: Encoding, before: String, after: String) {
                self.encoding = encoding
                self.before = before
                self.after = after
            }
        }

        public var original: String
        public var decoded: String
        public var steps: [Step]
        public var confidence: Double

        public init(original: String, decoded: String, steps: [Step], confidence: Double) {
            self.original = original
            self.decoded = decoded
            self.steps = steps
            self.confidence = confidence
        }

        /// Convenience for preview metadata: a small JSON string with the decoded content.
        public func metadataJSON() -> String? {
            let stepStrings = steps.map { $0.encoding.rawValue }
            let object: [String: Any] = [
                "encoding": stepStrings.count == 1 ? (stepStrings.first ?? "") : "nested",
                "steps": stepStrings,
                "decodedPreview": decoded
            ]
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [])
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    private let maxDepth: Int

    public init(maxDepth: Int = 3) {
        self.maxDepth = maxDepth
    }

    public func detect(in text: String) -> [Detection] {
        guard let detection = decodeNested(from: text) else { return [] }
        return [detection]
    }

    private func decodeNested(from text: String) -> Detection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var current = trimmed
        var steps: [Detection.Step] = []
        steps.reserveCapacity(maxDepth)

        for _ in 0..<maxDepth {
            if let next = decodeURLIfLikely(current) {
                steps.append(.init(encoding: .url, before: current, after: next))
                current = next
                continue
            }

            if let next = decodeBase64IfLikely(current) {
                steps.append(.init(encoding: .base64, before: current, after: next))
                current = next
                continue
            }

            break
        }

        guard !steps.isEmpty else { return nil }
        guard current != trimmed else { return nil }

        let confidence: Double = steps.count > 1 ? 0.9 : 0.85
        return Detection(original: trimmed, decoded: current, steps: steps, confidence: confidence)
    }

    private func decodeURLIfLikely(_ text: String) -> String? {
        guard text.contains("%") else { return nil }
        // Require at least one percent-escape to avoid false positives.
        guard text.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil else {
            return nil
        }
        guard let decoded = text.removingPercentEncoding, decoded != text else { return nil }
        return decoded
    }

    private func decodeBase64IfLikely(_ text: String) -> String? {
        // Conservative base64 heuristic to avoid decoding arbitrary short strings.
        // - Must be ASCII only
        // - Must be a multiple of 4 when whitespace is removed
        // - Must contain only base64 alphabet + optional padding
        let s = text.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard s.count >= 8 else { return nil }
        guard s.allSatisfy({ $0.isASCII }) else { return nil }
        guard s.count % 4 == 0 else { return nil }
        guard s.range(of: "^[A-Za-z0-9+/]+={0,2}$", options: .regularExpression) != nil else {
            return nil
        }

        guard let data = Data(base64Encoded: s) else { return nil }
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }

        let trimmedDecoded = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDecoded.isEmpty else { return nil }

        // Ensure it didn't decode back to the same content (rare but possible).
        guard trimmedDecoded != text else { return nil }

        return trimmedDecoded
    }
}
