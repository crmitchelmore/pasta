import Foundation

/// Receives remote history while the Mac's panel is closed. The same gate is
/// used by manual sync so a timer can never overlap a push-and-pull request.
@MainActor
public final class SyncReceiveScheduler {
    private let waitForNextAttempt: @Sendable () async throws -> Void
    private var receiveTask: Task<Void, Never>?
    private var isOperationRunning = false

    public init(
        waitForNextAttempt: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(60))
        }
    ) {
        self.waitForNextAttempt = waitForNextAttempt
    }

    deinit { receiveTask?.cancel() }

    /// Runs immediately, then waits between attempts (including failures).
    /// Repeated starts are idempotent; stop cancels the current receive too.
    public func start(
        receive: @escaping @MainActor () async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard receiveTask == nil else { return }
        let waitForNextAttempt = waitForNextAttempt
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.run(receive)
                } catch SyncPullService.PullError.alreadyInProgress {
                    // A manual request owns the transport. Try next interval.
                } catch {
                    guard !Task.isCancelled else { return }
                    onError(error)
                }
                guard !Task.isCancelled else { return }
                do { try await waitForNextAttempt() }
                catch { return }
            }
        }
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    public func run(_ operation: @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !isOperationRunning else { throw SyncPullService.PullError.alreadyInProgress }
        isOperationRunning = true
        defer { isOperationRunning = false }
        try await operation()
    }
}
