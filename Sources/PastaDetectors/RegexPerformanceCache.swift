import Foundation

/// Memoizes `RegexPerformanceEvaluator` results so repeated SwiftUI body
/// evaluations do not re-run the benchmark for patterns that have not changed.
///
/// The evaluator runs three match passes over a ~15 KB sample, which is far too
/// expensive to repeat on every re-render of a detector badge.
public final class RegexPerformanceCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let patterns: [String]
        public let optionsRawValue: UInt

        public init(patterns: [String], options: NSRegularExpression.Options) {
            self.patterns = patterns
            self.optionsRawValue = options.rawValue
        }
    }

    public static let shared = RegexPerformanceCache()

    private let limit: Int
    private let lock = NSLock()
    private var storage: [Key: RegexPerformanceResult] = [:]
    /// Insertion order, oldest first. Used to bound the cache.
    private var insertionOrder: [Key] = []

    public init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    /// Cached rating for a single pattern, evaluating it on a miss.
    public func result(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> RegexPerformanceResult {
        result(for: Key(patterns: [pattern], options: options)) {
            RegexPerformanceEvaluator.evaluate(pattern: pattern, options: options)
        }
    }

    /// Cached rating for a list of patterns, evaluating them on a miss.
    public func result(patterns: [String]) -> RegexPerformanceResult {
        result(for: Key(patterns: patterns, options: [])) {
            RegexPerformanceEvaluator.evaluate(patterns: patterns)
        }
    }

    /// The stored result for `key`, if it has already been evaluated.
    public func cached(_ key: Key) -> RegexPerformanceResult? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        insertionOrder.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    private func result(for key: Key, evaluate: () -> RegexPerformanceResult) -> RegexPerformanceResult {
        if let cached = cached(key) { return cached }

        let result = evaluate()

        lock.lock()
        defer { lock.unlock() }
        if storage[key] == nil {
            storage[key] = result
            insertionOrder.append(key)
            while insertionOrder.count > limit {
                let oldest = insertionOrder.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
        return storage[key] ?? result
    }
}
