import Foundation

/// Shared `NSRegularExpression` matching for the value detectors.
///
/// Compiled patterns are cached by pattern string: detectors run on every
/// clipboard change with a fixed handful of patterns, and ICU compilation
/// dominated each call.
enum RegexMatching {
    /// Detectors only inspect the head of very large inputs.
    static let maxScanLength = 30_000

    private static let cache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 128
        return cache
    }()

    /// A compiled (and cached) regex, or nil when the pattern is invalid.
    static func regex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue)::\(pattern)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache.setObject(compiled, forKey: key)
        return compiled
    }

    /// Every match of `pattern` in the first `maxScanLength` characters of
    /// `text`, returning capture group 1 when the pattern has one that
    /// participated and the whole match otherwise.
    static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = regex(for: pattern) else { return [] }
        let clamped = text.count > maxScanLength ? String(text.prefix(maxScanLength)) : text
        let range = NSRange(clamped.startIndex..<clamped.endIndex, in: clamped)
        let results = regex.matches(in: clamped, options: [], range: range)
        var out: [String] = []
        out.reserveCapacity(results.count)
        for match in results {
            let selected: NSRange
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                selected = match.range(at: 1)
            } else {
                selected = match.range(at: 0)
            }
            guard let valueRange = Range(selected, in: clamped) else { continue }
            out.append(String(clamped[valueRange]))
        }
        return out
    }
}
