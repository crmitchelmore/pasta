import XCTest
@testable import PastaSync

@MainActor
final class SyncReceiveSchedulerTests: XCTestCase {
    func testReceivesAtLaunchAndRetriesFailedAccountLookupNextInterval() async throws {
        let clock = ReceiveTestClock()
        let firstAttempt = expectation(description: "launch attempts receiving")
        let failure = expectation(description: "account failure is reported")
        let recovered = expectation(description: "next interval receives after account recovery")
        let scheduler = SyncReceiveScheduler { try await clock.wait() }
        defer { scheduler.stop() }
        var attempts = 0
        scheduler.start(receive: {
            attempts += 1
            if attempts == 1 {
                firstAttempt.fulfill()
                throw TestError.accountUnavailable
            }
            recovered.fulfill()
        }, onError: { _ in failure.fulfill() })

        await fulfillment(of: [firstAttempt, failure], timeout: 2)
        await clock.advance()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(attempts, 2)
    }

    func testBackgroundAttemptWaitsForNextIntervalWhenManualSyncOwnsTransport() async throws {
        let clock = ReceiveTestClock()
        let manualGate = ReceiveTestClock()
        let manualStarted = expectation(description: "manual sync started")
        let intervalStarted = expectation(description: "busy background attempt skipped")
        let received = expectation(description: "receiving resumes after manual sync")
        let scheduler = SyncReceiveScheduler {
            intervalStarted.fulfill()
            try await clock.wait()
        }
        defer { scheduler.stop() }
        let manual = Task {
            try await scheduler.run {
                manualStarted.fulfill()
                try await manualGate.wait()
            }
        }
        await fulfillment(of: [manualStarted], timeout: 2)
        var receives = 0
        scheduler.start(receive: {
            receives += 1
            received.fulfill()
        }, onError: { _ in XCTFail("An overlapping manual sync is not an account failure") })
        await fulfillment(of: [intervalStarted], timeout: 2)
        XCTAssertEqual(receives, 0)
        await manualGate.advance()
        try await manual.value
        await clock.advance()
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(receives, 1)
    }

    func testStopCancelsInFlightReceiveAndRestartDoesNotOverlapIt() async throws {
        let remoteGate = ReceiveTestClock()
        let clock = ReceiveTestClock()
        let started = expectation(description: "remote receive suspended")
        let cancelled = expectation(description: "remote receive cancelled on stop")
        let restarted = expectation(description: "restart receives again")
        let scheduler = SyncReceiveScheduler { try await clock.wait() }
        defer { scheduler.stop() }
        scheduler.start(receive: {
            started.fulfill()
            do { try await remoteGate.wait() }
            catch {
                cancelled.fulfill()
                throw error
            }
        }, onError: { _ in XCTFail("Stopping must not report a sync error") })
        await fulfillment(of: [started], timeout: 2)
        do {
            try await scheduler.run { XCTFail("Manual sync overlapped the active receiver") }
            XCTFail("Expected overlap rejection")
        } catch SyncPullService.PullError.alreadyInProgress {}
        scheduler.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        scheduler.start(receive: { restarted.fulfill() }, onError: { _ in XCTFail("Restart failed") })
        await fulfillment(of: [restarted], timeout: 2)
    }

    func testRepeatedStartDoesNotCreateAnotherLoopAndStopPreventsNextAttempt() async throws {
        let clock = ReceiveTestClock()
        let firstAttempt = expectation(description: "single launch receive")
        let scheduler = SyncReceiveScheduler { try await clock.wait() }
        var attempts = 0
        let receive: @MainActor () async throws -> Void = {
            attempts += 1
            firstAttempt.fulfill()
        }
        scheduler.start(receive: receive, onError: { _ in XCTFail("Unexpected error") })
        scheduler.start(receive: receive, onError: { _ in XCTFail("Unexpected error") })
        await fulfillment(of: [firstAttempt], timeout: 2)
        scheduler.stop()
        await clock.advance()
        // A manual operation still works after the background lifecycle stops.
        try await scheduler.run {}
        await Task.yield()
        XCTAssertEqual(attempts, 1)
    }

    private enum TestError: Error { case accountUnavailable }
}

/// A controllable interval/remote wait with real task cancellation semantics.
private actor ReceiveTestClock {
    private var credits = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func wait() async throws {
        try Task.checkCancellation()
        if credits > 0 {
            credits -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { credits += 1; return }
        waiters.removeFirst().1.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
