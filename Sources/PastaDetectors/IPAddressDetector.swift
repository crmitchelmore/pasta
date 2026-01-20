import Foundation

public struct IPAddressDetector {
    public struct Detection: Equatable {
        public var address: String
        /// "v4" or "v6"
        public var version: String
        public var isPrivate: Bool
        public var isLoopback: Bool
        public var isLinkLocal: Bool
        public var isMulticast: Bool
        public var confidence: Double

        public init(
            address: String,
            version: String,
            isPrivate: Bool,
            isLoopback: Bool,
            isLinkLocal: Bool,
            isMulticast: Bool,
            confidence: Double
        ) {
            self.address = address
            self.version = version
            self.isPrivate = isPrivate
            self.isLoopback = isLoopback
            self.isLinkLocal = isLinkLocal
            self.isMulticast = isMulticast
            self.confidence = confidence
        }
    }

    public init() {}

    public func detect(in text: String) -> [Detection] {
        var detections: [Detection] = []
        detections.reserveCapacity(6)

        detections.append(contentsOf: detectIPv4(in: text))
        detections.append(contentsOf: detectIPv6(in: text))

        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(detections.count)
        for d in detections {
            let key = d.address.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(d)
        }

        return out
    }

    private func detectIPv4(in text: String) -> [Detection] {
        let pattern = #"(?<![0-9])((?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Detection] = []
        results.reserveCapacity(matches.count)

        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let address = String(text[r])
            let flags = ipv4Flags(address)
            results.append(
                Detection(
                    address: address,
                    version: "v4",
                    isPrivate: flags.isPrivate,
                    isLoopback: flags.isLoopback,
                    isLinkLocal: flags.isLinkLocal,
                    isMulticast: flags.isMulticast,
                    confidence: 0.9
                )
            )
        }

        return results
    }

    private func detectIPv6(in text: String) -> [Detection] {
        let pattern = #"(?i)(?<![0-9a-f])((?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,5}(?::[0-9a-f]{1,4}){1,2}|(?:[0-9a-f]{1,4}:){1,4}(?::[0-9a-f]{1,4}){1,3}|(?:[0-9a-f]{1,4}:){1,3}(?::[0-9a-f]{1,4}){1,4}|(?:[0-9a-f]{1,4}:){1,2}(?::[0-9a-f]{1,4}){1,5}|[0-9a-f]{1,4}:(?::[0-9a-f]{1,4}){1,6}|:(?::[0-9a-f]{1,4}){1,7}|fe80:(?::[0-9a-f]{0,4}){0,4}%[0-9a-z]+|::(?:ffff(?::0{1,4}){0,1}:){0,1}(?:\d{1,3}\.){3}\d{1,3}|(?:[0-9a-f]{1,4}:){1,4}:(?:\d{1,3}\.){3}\d{1,3})(?![0-9a-f])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Detection] = []
        results.reserveCapacity(matches.count)

        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let address = String(text[r])
            let flags = ipv6Flags(address)
            results.append(
                Detection(
                    address: address,
                    version: "v6",
                    isPrivate: flags.isPrivate,
                    isLoopback: flags.isLoopback,
                    isLinkLocal: flags.isLinkLocal,
                    isMulticast: flags.isMulticast,
                    confidence: 0.85
                )
            )
        }

        return results
    }

    private func ipv4Flags(_ address: String) -> (isPrivate: Bool, isLoopback: Bool, isLinkLocal: Bool, isMulticast: Bool) {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return (false, false, false, false) }

        let first = parts[0]
        let second = parts[1]

        let isLoopback = first == 127
        let isLinkLocal = first == 169 && second == 254
        let isPrivate = first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
        let isMulticast = (224...239).contains(first)

        return (isPrivate, isLoopback, isLinkLocal, isMulticast)
    }

    private func ipv6Flags(_ address: String) -> (isPrivate: Bool, isLoopback: Bool, isLinkLocal: Bool, isMulticast: Bool) {
        let lower = address.lowercased()

        let isLoopback = lower == "::1" || lower == "0:0:0:0:0:0:0:1"
        let isLinkLocal = lower.hasPrefix("fe80:")
        let isMulticast = lower.hasPrefix("ff")
        let isPrivate = lower.hasPrefix("fc") || lower.hasPrefix("fd")

        return (isPrivate, isLoopback, isLinkLocal, isMulticast)
    }
}
