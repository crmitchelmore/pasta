import Foundation

/// Turns text into unit-length vectors. Implementations must return one
/// vector per input, in input order.
public protocol TextEmbedding: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Calls an OpenAI-format `/embeddings` endpoint (OpenAI, Azure OpenAI, or a
/// local OpenAI-compatible server).
public struct RemoteEmbeddingClient: TextEmbedding {
    /// Inputs per request. OpenAI accepts up to 2048, but smaller batches keep
    /// requests well under token limits and make progress visible.
    public static let maxBatchSize = 64

    public let configuration: SemanticSearchConfiguration
    private let apiKey: String
    private let session: URLSession
    private let retryPolicy: JevRetryPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        configuration: SemanticSearchConfiguration,
        apiKey: String?,
        session: URLSession = .shared,
        retryPolicy: JevRetryPolicy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var start = 0
        while start < texts.count {
            let end = min(texts.count, start + Self.maxBatchSize)
            vectors += try await embedBatch(Array(texts[start..<end]))
            start = end
        }
        return vectors
    }

    func makeRequest(_ texts: [String]) throws -> URLRequest {
        guard let url = configuration.endpointURL else { throw SemanticSearchError.invalidEndpoint }
        if configuration.provider.requiresAPIKey && apiKey.isEmpty { throw SemanticSearchError.missingAPIKey }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            switch configuration.provider {
            case .azureOpenAI: request.setValue(apiKey, forHTTPHeaderField: "api-key")
            case .openAI, .openAICompatible: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        var body: [String: Any] = [
            "input": texts,
            "model": configuration.effectiveModel,
            "encoding_format": "float"
        ]
        if let dimensions = configuration.requestedDimensions { body["dimensions"] = dimensions }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func decode(_ data: Data, expectedCount: Int) throws -> [[Float]] {
        let response: EmbeddingResponse
        do {
            response = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        } catch {
            throw SemanticSearchError.invalidResponse("could not decode embeddings.")
        }
        guard response.data.count == expectedCount else {
            throw SemanticSearchError.invalidResponse("expected \(expectedCount) embeddings, got \(response.data.count).")
        }
        let ordered = response.data.enumerated()
            .sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }
            .map(\.element.embedding)
        guard let dimensions = ordered.first?.count, dimensions > 0,
              ordered.allSatisfy({ $0.count == dimensions }) else {
            throw SemanticSearchError.invalidResponse("embeddings have inconsistent dimensions.")
        }
        return try ordered.map { vector in
            guard let normalized = VectorMath.normalized(vector) else {
                throw SemanticSearchError.invalidResponse("an embedding was empty or not finite.")
            }
            return normalized
        }
    }

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        let request = try makeRequest(texts)
        var retry = 0
        while true {
            try Task.checkCancellation()
            let failure: SemanticSearchError
            var retryAfter: TimeInterval?
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw SemanticSearchError.invalidResponse("no HTTP response.")
                }
                if (200..<300).contains(http.statusCode) {
                    return try Self.decode(data, expectedCount: texts.count)
                }
                failure = SemanticSearchError.from(status: http.statusCode, body: data)
                retryAfter = JevClassifier.retryAfter(from: http)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                failure = SemanticSearchError(error)
            }
            guard failure.isRetryable, retry < retryPolicy.maxRetries else { throw failure }
            try await sleep(retryPolicy.delay(forRetry: retry, retryAfter: retryAfter))
            retry += 1
        }
    }

    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Float]
            let index: Int?
        }
        let data: [Item]
    }
}
