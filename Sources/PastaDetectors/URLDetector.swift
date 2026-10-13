import Foundation

public struct URLDetector {
    public struct Detection: Equatable {
        public var url: String
        public var domain: String
        public var category: String
        public var confidence: Double
        /// Incremented by the caller (e.g. when the same URL is seen again).
        public var hotCount: Int

        public init(url: String, domain: String, category: String, confidence: Double, hotCount: Int = 1) {
            self.url = url
            self.domain = domain
            self.category = category
            self.confidence = confidence
            self.hotCount = hotCount
        }
    }

    public init() {}

    private static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public func detect(in text: String) -> [Detection] {
        let decodedText = URLDetector.urlDecoded(text)

        var detections: [Detection] = []
        // Prefer matches from the decoded form when the input is URL-encoded.
        if decodedText != text {
            detections.append(contentsOf: URLDetector.detectURLs(in: decodedText))
        }
        detections.append(contentsOf: URLDetector.detectURLs(in: text))

        // De-dupe while preserving first-seen order.
        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(detections.count)
        for d in detections {
            let key = d.url.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(d)
        }

        return out
    }

    private static func detectURLs(in text: String) -> [Detection] {
        guard let detector = linkDetector else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        var results: [Detection] = []
        results.reserveCapacity(matches.count)

        for match in matches {
            var resolvedURL: URL?

            // Prefer decoding the raw matched text when it's percent-encoded.
            if let matchRange = Range(match.range, in: text) {
                let raw = String(text[matchRange])
                if let decoded = raw.removingPercentEncoding, decoded != raw, let decodedURL = URL(string: decoded) {
                    resolvedURL = decodedURL
                }
            }

            if resolvedURL == nil {
                resolvedURL = match.url
            }

            guard let url = resolvedURL else { continue }
            let scheme = (url.scheme ?? "").lowercased()
            guard scheme == "http" || scheme == "https" || scheme == "ftp" else { continue }

            let absoluteString = url.absoluteString
            let domain = (url.host ?? "").lowercased()
            guard !domain.isEmpty else { continue }

            results.append(
                Detection(
                    url: absoluteString,
                    domain: domain,
                    category: categorize(domain: domain),
                    confidence: 0.95,
                    hotCount: 1
                )
            )
        }

        return results
    }

    private static func categorize(domain: String) -> String {
        // Basic site categorization; callers can map this into UI badges.
        if domain == "github.com" || domain.hasSuffix(".github.com") { return "github" }
        if domain == "stackoverflow.com" || domain.hasSuffix(".stackoverflow.com") { return "stackoverflow" }
        if domain == "docs.google.com" { return "google-docs" }
        if domain == "google.com" || domain.hasSuffix(".google.com") { return "google" }
        if domain == "developer.apple.com" { return "apple-developer" }
        if domain == "apple.com" || domain.hasSuffix(".apple.com") { return "apple" }
        if domain == "youtube.com" || domain == "youtu.be" { return "youtube" }
        if domain == "twitter.com" || domain == "x.com" { return "x" }

        // Generic buckets.
        if domain.hasSuffix(".edu") { return "education" }
        if domain.hasSuffix(".gov") { return "government" }

        return "other"
    }

    private static func urlDecoded(_ text: String) -> String {
        // Best-effort decode; if it's not actually URL-encoded, keep original.
        guard let decoded = text.removingPercentEncoding else { return text }
        return decoded
    }

    // MARK: - Cached domains

    private final class DomainSet: NSObject {
        let domains: Set<String>
        init(_ domains: Set<String>) { self.domains = domains }
    }

    /// Detection is a pure function of the text, and each call runs
    /// NSDataDetector (~60µs per URL). The history panel recounts domains for
    /// every URL entry whenever the history changes, so remember the answer.
    private static let domainCache: NSCache<NSString, DomainSet> = {
        let cache = NSCache<NSString, DomainSet>()
        cache.countLimit = 20_000
        return cache
    }()

    /// The distinct domains of the URLs in `text` (same as collecting
    /// `detect(in:)`'s domains), cached by text. Safe from any thread.
    public static func domains(in text: String) -> Set<String> {
        let key = text as NSString
        if let cached = domainCache.object(forKey: key) {
            return cached.domains
        }
        let domains = Set(URLDetector().detect(in: text).map(\.domain))
        domainCache.setObject(DomainSet(domains), forKey: key)
        return domains
    }
}
