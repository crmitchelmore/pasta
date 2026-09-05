import Foundation

/// Owns each request's task so cancellation of a view/foreground caller cannot
/// discard the next activation while an earlier account lookup is suspended.
@MainActor
public final class SyncRequestQueue {
    private var tail: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func run(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let id = UUID()
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        tasks[id] = task
        await task.value
        tasks[id] = nil
        if tasks.isEmpty { tail = nil }
    }

    /// Used for explicit consent withdrawal, not routine scene transitions.
    public func cancelAll() {
        for task in tasks.values { task.cancel() }
    }
}
