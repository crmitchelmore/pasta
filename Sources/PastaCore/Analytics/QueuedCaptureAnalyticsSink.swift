import Foundation

/// The whole network surface of Pasta's analytics: one `POST` of an audited JSON
/// body to a single configured capture endpoint.
///
/// No vendor SDK is used. Analytics SDKs typically add a remote-config fetch,
/// autocapture, session replay and error capture — all of which are explicitly
/// ruled out for a clipboard manager. Posting the typed payload directly keeps the
/// network surface to one documented request that can be read in full below.
///
/// Events are queued on disk so a flaky connection does not lose the day's data;
/// the queue is pruned to 7 days and 1,000 events, and is deleted outright on
/// `purge()`. Nothing is ever sent before `reopen()`, which the controller only
/// calls once consent is persisted.
public actor QueuedCaptureAnalyticsSink: ProductAnalyticsSink {
    public struct Configuration: Sendable {
        public let projectKey: String
        public let endpoint: URL

        public init(projectKey: String, endpoint: URL) {
            self.projectKey = projectKey
            self.endpoint = endpoint
        }

        /// EU ingestion host by default, so analytics data never crosses to US infrastructure.
        public static let defaultHost = "https://eu.i.posthog.com"

        /// Returns `nil` — meaning "analytics are a permanent no-op" — unless a non-empty
        /// project key is present. Local builds and forks ship without one.
        ///
        /// `infoValue` reads the app bundle in production and is injected in tests; the
        /// key is a *public*, write-only ingestion key, so shipping it in a client is safe.
        public static func resolve(
            environment: [String: String],
            infoValue: (String) -> String?
        ) -> Configuration? {
            let key = environment["POSTHOG_PROJECT_KEY"] ?? infoValue("PostHogProjectKey")
            let host = environment["POSTHOG_HOST"] ?? infoValue("PostHogHost") ?? defaultHost
            guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let baseURL = URL(string: host), baseURL.scheme != nil
            else { return nil }
            return Configuration(projectKey: key, endpoint: baseURL.appendingPathComponent("capture"))
        }
    }

    private struct QueuedEvent: Codable, Sendable {
        let createdAt: Date
        let event: String
        let distinctID: String
        let properties: [String: String]
    }

    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumQueuedEvents = 1_000

    private let configuration: Configuration
    private let queueURL: URL
    private let session: URLSession
    private var queue: [QueuedEvent]
    private var isOpen = false

    public init(configuration: Configuration, queueURL: URL, session: URLSession = .shared) {
        self.configuration = configuration
        self.queueURL = queueURL
        self.session = session
        self.queue = Self.pruned(Self.loadQueue(from: queueURL))
    }

    public func reopen() async throws {
        isOpen = true
        try await flush()
    }

    public func capture(_ payload: ProductAnalyticsPayload) async throws {
        guard isOpen else { return }
        queue.append(QueuedEvent(
            createdAt: Date(),
            event: payload.event,
            distinctID: payload.distinctID.uuidString,
            properties: payload.properties
        ))
        queue = Self.pruned(queue)
        try persistQueue()
        try await flush()
    }

    public func purge() async throws {
        isOpen = false
        queue.removeAll(keepingCapacity: false)
        if FileManager.default.fileExists(atPath: queueURL.path) {
            try FileManager.default.removeItem(at: queueURL)
        }
    }

    public func close() async { isOpen = false }

    private func flush() async throws {
        guard isOpen else { return }
        while let next = queue.first {
            var properties: [String: Any] = next.properties
            properties["distinct_id"] = next.distinctID
            properties["$lib"] = "pasta"
            properties["$lib_version"] = "1"
            properties["timestamp"] = ISO8601DateFormatter().string(from: next.createdAt)
            let body: [String: Any] = [
                "api_key": configuration.projectKey,
                "event": next.event,
                "properties": properties
            ]
            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            queue.removeFirst()
            try persistQueue()
        }
    }

    private func persistQueue() throws {
        if queue.isEmpty {
            if FileManager.default.fileExists(atPath: queueURL.path) {
                try FileManager.default.removeItem(at: queueURL)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: queueURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(queue).write(to: queueURL, options: [.atomic])
    }

    private static func loadQueue(from url: URL) -> [QueuedEvent] {
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([QueuedEvent].self, from: data)
        else { return [] }
        return events
    }

    private static func pruned(_ events: [QueuedEvent], now: Date = Date()) -> [QueuedEvent] {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        return Array(events.filter { $0.createdAt >= cutoff }.suffix(maximumQueuedEvents))
    }
}
