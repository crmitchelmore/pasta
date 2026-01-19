import Foundation

public struct EmailDetector {
    public struct Detection: Equatable {
        public var email: String
        public var confidence: Double

        public init(email: String, confidence: Double) {
            self.email = email
            self.confidence = confidence
        }
    }

    public init() {}

    /// Detects email addresses in `text`.
    ///
    /// - Returns: Detected emails in document order, with a confidence score.
    public func detect(in text: String) -> [Detection] {
        // RFC 5322 is huge; we use a pragmatic approximation that performs well for clipboard content.
        // Local-part: letters/digits and common specials, must start/end with alnum.
        // Domain: labels separated by dots, final TLD 2+ chars.
        // Boundary rules are intentionally conservative: don't match when surrounded by token characters.
        let pattern = #"(?i)(?<![A-Z0-9._%+\-])([A-Z0-9](?:[A-Z0-9._%+\-]{0,62}[A-Z0-9])?)@([A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9\-]{0,61}[A-Z0-9])?)+)(?![A-Z0-9_%+\-])"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var seen = Set<String>()
        var detections: [Detection] = []
        detections.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: text)
            else {
                continue
            }

            let email = String(text[fullRange]).lowercased()
            guard seen.insert(email).inserted else { continue }
            detections.append(Detection(email: email, confidence: 0.95))
        }

        return detections
    }
}
