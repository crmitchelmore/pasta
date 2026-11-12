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

    /// Cancelling the caller must stop detached background work (e.g. a
    /// superseded search) instead of letting it run to completion.
    func testReturnsResultAndPropagatesCancellationIntoDetachedWork() async {
        let result = await withCancellableDetachedTask { 21 * 2 }
        XCTAssertEqual(result, 42)

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
}
