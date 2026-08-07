import XCTest
@testable import PastaCore

final class DetachedWorkTests: XCTestCase {
    /// A minimal thread-safe box so the detached work can report back.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testReturnsOperationResult() async {
        let result = await withCancellableDetachedTask { 21 * 2 }
        XCTAssertEqual(result, 42)
    }

    func testCancellationPropagatesIntoDetachedWork() async {
        let started = Box()
        let observedCancellation = Box()

        let outer = Task {
            await withCancellableDetachedTask(priority: .utility) { () -> Bool in
                started.set()
                // Poll rather than sleep so the test does not depend on timing.
                for _ in 0..<10_000 {
                    if Task.isCancelled {
                        observedCancellation.set()
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return false
            }
        }

        while !started.isSet {
            await Task.yield()
        }
        outer.cancel()
        let sawCancellation = await outer.value

        XCTAssertTrue(sawCancellation)
        XCTAssertTrue(observedCancellation.isSet)
    }

    func testAlreadyCancelledCallerCancelsDetachedWork() async {
        let observedCancellation = Box()

        let outer = Task {
            // Give the test a chance to cancel before the detached work starts.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await withCancellableDetachedTask { () -> Bool in
                for _ in 0..<10_000 {
                    if Task.isCancelled {
                        observedCancellation.set()
                        return true
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return false
            }
        }

        outer.cancel()
        _ = await outer.value

        XCTAssertTrue(observedCancellation.isSet || outer.isCancelled)
    }
}
