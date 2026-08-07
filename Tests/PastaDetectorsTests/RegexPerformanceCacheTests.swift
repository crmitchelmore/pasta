import XCTest
@testable import PastaDetectors

final class RegexPerformanceCacheTests: XCTestCase {
    func testRepeatedLookupsReuseTheMemoizedResult() {
        let cache = RegexPerformanceCache()
        let pattern = #"\b[A-Z]{3}-\d{4}\b"#

        let first = cache.result(pattern: pattern)
        let second = cache.result(pattern: pattern)

        // The benchmark timing is baked into `details`, so identical details
        // prove the second lookup did not re-run the benchmark.
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.cached(RegexPerformanceCache.Key(patterns: [pattern], options: [])), first)
    }

    func testOptionsArePartOfTheCacheKey() {
        let cache = RegexPerformanceCache()
        let pattern = "abc"

        _ = cache.result(pattern: pattern, options: [])
        _ = cache.result(pattern: pattern, options: [.caseInsensitive])

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.cached(RegexPerformanceCache.Key(patterns: [pattern], options: [])))
        XCTAssertNotNil(cache.cached(RegexPerformanceCache.Key(patterns: [pattern], options: [.caseInsensitive])))
    }

    func testCacheIsBoundedAndEvictsOldestEntries() {
        let cache = RegexPerformanceCache(limit: 2)

        _ = cache.result(pattern: "a")
        _ = cache.result(pattern: "b")
        _ = cache.result(pattern: "c")

        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.cached(RegexPerformanceCache.Key(patterns: ["a"], options: [])))
        XCTAssertNotNil(cache.cached(RegexPerformanceCache.Key(patterns: ["c"], options: [])))
    }

    func testPatternListLookupIsMemoized() {
        let cache = RegexPerformanceCache()
        let patterns = ["[0-9]+", "[a-z]+"]

        let first = cache.result(patterns: patterns)
        let second = cache.result(patterns: patterns)

        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.count, 1)
    }

    func testInvalidPatternIsCachedAsInvalid() {
        let cache = RegexPerformanceCache()

        let result = cache.result(pattern: "([unterminated")

        XCTAssertEqual(result.rating, .invalid)
        XCTAssertNotNil(result.compileError)
        XCTAssertEqual(cache.result(pattern: "([unterminated"), result)
    }

    func testIsValidOnlyChecksCompilation() {
        XCTAssertTrue(RegexPerformanceEvaluator.isValid(pattern: "[a-z]+"))
        XCTAssertTrue(RegexPerformanceEvaluator.isValid(pattern: "ABC", options: [.caseInsensitive]))
        XCTAssertFalse(RegexPerformanceEvaluator.isValid(pattern: "([unterminated"))
        XCTAssertFalse(RegexPerformanceEvaluator.isValid(pattern: "   "))
    }
}
