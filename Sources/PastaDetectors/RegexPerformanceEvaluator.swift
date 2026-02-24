import Foundation

public enum RegexPerformanceRating: String, Codable, CaseIterable, Sendable {
    case fast
    case reasonable
    case slow
    case invalid

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .reasonable: return "Reasonable"
        case .slow: return "Slow"
        case .invalid: return "Invalid"
        }
    }
}

public struct RegexPerformanceResult: Equatable, Sendable {
    public var rating: RegexPerformanceRating
    public var details: String
    public var compileError: String?

    public init(rating: RegexPerformanceRating, details: String, compileError: String? = nil) {
        self.rating = rating
        self.details = details
        self.compileError = compileError
    }
}

public enum RegexPerformanceEvaluator {
    private static let benchmarkSample: String = {
        let digits = String(repeating: "1234567890", count: 500)
        let prose = String(repeating: "alpha beta gamma delta epsilon zeta eta theta iota kappa ", count: 120)
        let mixed = String(repeating: "token=abcd1234 value=xyz9876 https://example.com/path?a=1 ", count: 150)
        return [digits, prose, mixed].joined(separator: "\n")
    }()

    public static func evaluate(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> RegexPerformanceResult {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RegexPerformanceResult(
                rating: .invalid,
                details: "Enter a regular expression pattern.",
                compileError: "Pattern is empty."
            )
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: trimmed, options: options)
        } catch {
            return RegexPerformanceResult(
                rating: .invalid,
                details: "Could not compile this regex.",
                compileError: error.localizedDescription
            )
        }

        let staticRisk = staticRiskScore(for: trimmed)
        let benchmarkMilliseconds = benchmark(regex: regex)
        let rating = rating(for: staticRisk, benchmarkMilliseconds: benchmarkMilliseconds)

        let details = "Benchmark: \(String(format: "%.2f", benchmarkMilliseconds)) ms • Risk: \(staticRisk)"
        return RegexPerformanceResult(rating: rating, details: details)
    }

    public static func evaluate(patterns: [String]) -> RegexPerformanceResult {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else {
            return RegexPerformanceResult(rating: .invalid, details: "No patterns configured.", compileError: "No patterns")
        }

        var worst: RegexPerformanceResult?
        for pattern in cleaned {
            let result = evaluate(pattern: pattern)
            if worst == nil || isWorse(result.rating, than: worst!.rating) {
                worst = result
            }
            if result.rating == .invalid {
                return result
            }
        }
        return worst ?? RegexPerformanceResult(rating: .invalid, details: "No patterns configured.", compileError: "No patterns")
    }

    private static func isWorse(_ left: RegexPerformanceRating, than right: RegexPerformanceRating) -> Bool {
        score(for: left) > score(for: right)
    }

    private static func score(for rating: RegexPerformanceRating) -> Int {
        switch rating {
        case .fast: return 0
        case .reasonable: return 1
        case .slow: return 2
        case .invalid: return 3
        }
    }

    private static func rating(for staticRisk: Int, benchmarkMilliseconds: Double) -> RegexPerformanceRating {
        if staticRisk >= 4 || benchmarkMilliseconds >= 15 {
            return .slow
        }
        if staticRisk >= 2 || benchmarkMilliseconds >= 5 {
            return .reasonable
        }
        return .fast
    }

    private static func benchmark(regex: NSRegularExpression) -> Double {
        let range = NSRange(benchmarkSample.startIndex..<benchmarkSample.endIndex, in: benchmarkSample)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 {
            _ = regex.numberOfMatches(in: benchmarkSample, options: [], range: range)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = end - start
        return Double(elapsedNanoseconds) / 1_000_000.0 / 3.0
    }

    private static func staticRiskScore(for pattern: String) -> Int {
        var risk = 0

        if pattern.count > 180 { risk += 1 }
        if pattern.count > 320 { risk += 1 }

        if pattern.range(of: #"\(.+[+*]\)[+*{]"#, options: .regularExpression) != nil {
            risk += 2
        }

        if pattern.range(of: #"\.\*.*\.\*"#, options: .regularExpression) != nil {
            risk += 1
        }

        if pattern.range(of: #"\\[1-9]"#, options: .regularExpression) != nil {
            risk += 1
        }

        if pattern.range(of: #"\(.+\|\|?.+\)"#, options: .regularExpression) != nil {
            risk += 1
        }

        if pattern.range(of: #"\(.+\|.+\|.+\|.+\|.+\)"#, options: .regularExpression) != nil {
            risk += 1
        }

        return risk
    }
}
