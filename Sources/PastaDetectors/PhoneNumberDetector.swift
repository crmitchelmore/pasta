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

    public func detect(in text: String) -> [Detection] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(matches.count)

        for match in matches {
            guard let number = match.phoneNumber else { continue }
            let normalized = number.replacingOccurrences(of: " ", with: "")
            guard seen.insert(normalized).inserted else { continue }
            out.append(Detection(phoneNumber: number, confidence: 0.9))
        }

        return out
    }
}
