import Foundation

/// Runs `operation` on a detached task while forwarding cancellation from the
/// calling task into it.
///
/// `Task.detached` deliberately does not inherit cancellation, so the common
/// `Task { await Task.detached { ... }.value }` shape leaves stale work running
/// (FTS reads, full-history scans) even after the caller cancelled. Wrapping the
/// detached task in a cancellation handler lets `Task.isCancelled` inside
/// `operation` bail out early.
public func withCancellableDetachedTask<T: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () async -> T
) async -> T {
    let work = Task.detached(priority: priority, operation: operation)
    return await withTaskCancellationHandler {
        await work.value
    } onCancel: {
        work.cancel()
    }
}
