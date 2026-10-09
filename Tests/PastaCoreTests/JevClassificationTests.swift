import XCTest
@testable import PastaCore

final class JevClassificationTests: XCTestCase {
    override func tearDown() {
        JevMockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Configuration

    func testConfigurationNeverStoresAPIKeyInDefaults() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        JevConfiguration(isEnabled: true, endpoint: "https://example.com", model: "test").save(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "pasta.jev.apiKey"))
        XCTAssertTrue(JevConfiguration.load(defaults: defaults).isEnabled)
    }

    func testDefaultsTargetTypeSafeSystemOne() {
        let configuration = JevConfiguration()
        XCTAssertEqual(configuration.endpoint, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(configuration.model, "jev-latest")
        XCTAssertFalse(configuration.includeSensitiveContent)
    }

    func testLoadMigratesLegacyEndpointAndModel() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(true, forKey: "pasta.jev.enabled")
        defaults.set("https://api.jev.ai/v1/classify", forKey: "pasta.jev.endpoint")
        defaults.set("jev", forKey: "pasta.jev.model")

        let configuration = JevConfiguration.load(defaults: defaults)

        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.endpoint, JevConfiguration.defaultEndpoint)
        XCTAssertEqual(configuration.model, JevConfiguration.defaultModel)
        XCTAssertEqual(defaults.string(forKey: "pasta.jev.endpoint"), JevConfiguration.defaultEndpoint)
        XCTAssertEqual(defaults.string(forKey: "pasta.jev.model"), JevConfiguration.defaultModel)
    }

    func testComparisonRequiresValidationForCurrentKeyEndpointAndModel() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var configuration = JevConfiguration(isEnabled: true)

        XCTAssertFalse(configuration.isComparisonAllowed(apiKey: "test-key", defaults: defaults))
        configuration.recordSuccessfulValidation(apiKey: "test-key", defaults: defaults)
        configuration.save(defaults: defaults)

        let reloaded = JevConfiguration.load(defaults: defaults)
        XCTAssertTrue(reloaded.isComparisonAllowed(apiKey: "test-key", defaults: defaults))
        XCTAssertFalse(reloaded.isComparisonAllowed(apiKey: "replacement-key", defaults: defaults))
        XCTAssertFalse(reloaded.isComparisonAllowed(apiKey: "", defaults: defaults))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("test-key") == true })

        configuration.endpoint = "https://proxy.example.com/v1/systemone"
        XCTAssertFalse(configuration.isComparisonAllowed(apiKey: "test-key", defaults: defaults))
        configuration.endpoint = JevConfiguration.defaultEndpoint
        configuration.model = "jev-preview"
        XCTAssertFalse(configuration.isComparisonAllowed(apiKey: "test-key", defaults: defaults))
    }

    func testInvalidatingValidationDisablesComparisonAcrossRelaunch() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let configuration = JevConfiguration(isEnabled: true)
        configuration.save(defaults: defaults)
        configuration.recordSuccessfulValidation(apiKey: "test-key", defaults: defaults)

        JevConfiguration.invalidateValidation(defaults: defaults)

        XCTAssertFalse(configuration.isValidated(apiKey: "test-key", defaults: defaults))
        XCTAssertFalse(JevConfiguration.load(defaults: defaults).isEnabled)
        XCTAssertFalse(configuration.isComparisonAllowed(apiKey: "test-key", defaults: defaults))
    }

    func testValidationDoesNotEnableComparisonWithoutUserOptIn() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let configuration = JevConfiguration()
        configuration.recordSuccessfulValidation(apiKey: "test-key", defaults: defaults)

        XCTAssertTrue(configuration.isValidated(apiKey: " test-key \n", defaults: defaults))
        XCTAssertFalse(configuration.isComparisonAllowed(apiKey: "test-key", defaults: defaults))
    }

    func testLoadKeepsCustomEndpointAndModel() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        JevConfiguration(endpoint: "https://proxy.example.com/v1/systemone", model: "jev-preview").save(defaults: defaults)

        let configuration = JevConfiguration.load(defaults: defaults)

        XCTAssertEqual(configuration.endpoint, "https://proxy.example.com/v1/systemone")
        XCTAssertEqual(configuration.model, "jev-preview")
    }

    func testEndpointMustBeHTTPS() {
        XCTAssertNil(JevConfiguration(endpoint: "http://api.typesafe.ai/v1/systemone").endpointURL)
        XCTAssertNil(JevConfiguration(endpoint: "not a url").endpointURL)
        XCTAssertEqual(JevConfiguration().endpointHost, "api.typesafe.ai")
    }

    // MARK: Request

    func testRequestUsesSystemOneChoiceSchema() async throws {
        JevMockURLProtocol.enqueue(status: 200, body: Self.successBody(choice: "url"))

        _ = try await makeClassifier().classify(content: "https://example.com", configuration: JevConfiguration(), apiKey: " secret-key ")

        let request = try XCTUnwrap(JevMockURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(JevMockURLProtocol.bodies.first)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "jev-latest")
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual(state["clipboard_content"] as? String, "https://example.com")
        let questions = try XCTUnwrap(json["questions"] as? [String: Any])
        let question = try XCTUnwrap(questions["content_type"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertTrue((question["instructions"] as? String)?.contains("`clipboard_content`") == true)
        let criteria = try XCTUnwrap(question["criteria"] as? [String: String])
        XCTAssertEqual(Set(criteria.keys), Set(JevSystemOneRequest.options.map(\.category.rawValue)))
        XCTAssertNil(criteria["image"])
        XCTAssertNil(criteria["screenshot"])
        XCTAssertNotNil(criteria["unknown"])
    }

    func testRequestCriteriaKeepDeclaredOrderWithOtherLast() throws {
        let body = try JevSystemOneRequest.body(content: "x", model: "jev-latest")
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        let positions = JevSystemOneRequest.options.map { option in
            text.range(of: "\"\(option.category.rawValue)\":")!.lowerBound
        }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(JevSystemOneRequest.options.last?.category, .unknown)
    }

    func testLongContentIsTruncated() throws {
        let content = String(repeating: "a", count: JevSystemOneRequest.maxContentCharacters + 50)
        let body = try JevSystemOneRequest.body(content: content, model: "jev-latest")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try XCTUnwrap(json["state"] as? [String: Any])
        XCTAssertEqual((state["clipboard_content"] as? String)?.count, JevSystemOneRequest.maxContentCharacters)
        XCTAssertNotNil(state["clipboard_content_note"])
    }

    // MARK: Response

    func testDecodesChoiceConfidenceProbabilitiesAndModel() async throws {
        JevMockURLProtocol.enqueue(status: 200, body: Self.successBody(choice: "phoneNumber", confidence: 0.82))

        let result = try await makeClassifier().classify(content: "+44 20 7946 0958", configuration: JevConfiguration(), apiKey: "key")

        XCTAssertEqual(result.category, .phoneNumber)
        XCTAssertEqual(result.rawChoice, "phoneNumber")
        XCTAssertEqual(result.confidence, 0.82)
        XCTAssertEqual(result.probabilities?["phoneNumber"], 0.9)
        XCTAssertEqual(result.modelVersion, "jev-1.13.0")
        XCTAssertEqual(result.inputTokens, 120)
        XCTAssertEqual(result.attempts, 1)
    }

    func testUnexpectedChoiceMapsToUnknownButKeepsRawChoice() async throws {
        JevMockURLProtocol.enqueue(status: 200, body: Self.successBody(choice: "image"))

        let result = try await makeClassifier().classify(content: "x", configuration: JevConfiguration(), apiKey: "key")

        XCTAssertEqual(result.category, .unknown)
        XCTAssertEqual(result.rawChoice, "image")
    }

    func testMissingAnswerIsInvalidResponse() async {
        JevMockURLProtocol.enqueue(status: 200, body: #"{"model":"jev-1.13.0","answers":{}}"#)

        await XCTAssertThrowsJevError(try await makeClassifier().classify(content: "x", configuration: JevConfiguration(), apiKey: "key")) { error in
            guard case .invalidResponse = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    // MARK: Errors and retries

    func testUnauthorizedIsFatalAndNotRetried() async {
        JevMockURLProtocol.enqueue(status: 401, body: #"{"detail":"Invalid API key"}"#)

        await XCTAssertThrowsJevError(try await makeClassifier().classify(content: "x", configuration: JevConfiguration(), apiKey: "bad")) { error in
            XCTAssertEqual(error, .unauthorized("Invalid API key"))
            XCTAssertTrue(error.isFatal)
        }
        XCTAssertEqual(JevMockURLProtocol.requests.count, 1)
    }

    func testValidationErrorSurfacesDetail() async {
        JevMockURLProtocol.enqueue(status: 422, body: #"{"detail":[{"loc":["body","model"],"msg":"Unknown model"}]}"#)

        await XCTAssertThrowsJevError(try await makeClassifier().classify(content: "x", configuration: JevConfiguration(), apiKey: "key")) { error in
            XCTAssertEqual(error, .validation("body.model: Unknown model"))
            XCTAssertTrue(error.isFatal)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(JevMockURLProtocol.requests.count, 1)
    }

    func testRetriesRateLimitAndOverloadThenSucceeds() async throws {
        let delays = DelayRecorder()
        JevMockURLProtocol.enqueue(status: 429, body: "{}", headers: ["Retry-After": "2"])
        JevMockURLProtocol.enqueue(status: 529, body: "{}")
        JevMockURLProtocol.enqueue(status: 200, body: Self.successBody(choice: "email"))

        let result = try await makeClassifier(delays: delays).classify(content: "a@b.com", configuration: JevConfiguration(), apiKey: "key")

        XCTAssertEqual(result.category, .email)
        XCTAssertEqual(result.attempts, 3)
        XCTAssertEqual(JevMockURLProtocol.requests.count, 3)
        let recorded = await delays.values
        XCTAssertEqual(recorded.first, 2)
        XCTAssertEqual(recorded.count, 2)
    }

    func testRetriesAreBounded() async {
        for _ in 0..<5 { JevMockURLProtocol.enqueue(status: 529, body: "{}") }

        await XCTAssertThrowsJevError(try await makeClassifier().classify(content: "x", configuration: JevConfiguration(), apiKey: "key")) { error in
            XCTAssertEqual(error, .overloaded)
        }
        XCTAssertEqual(JevMockURLProtocol.requests.count, 3)
    }

    func testRetriesHonorMillisecondHeaderBeforeSecondsHeader() async throws {
        let delays = DelayRecorder()
        JevMockURLProtocol.enqueue(status: 429, body: "{}", headers: ["retry-after-ms": "1500", "Retry-After": "9"])
        JevMockURLProtocol.enqueue(status: 200, body: Self.successBody(choice: "text"))

        _ = try await makeClassifier(delays: delays).classify(content: "hello", configuration: JevConfiguration(), apiKey: "key")

        let recorded = await delays.values
        XCTAssertEqual(recorded, [1.5])
    }

    func testInvalidMillisecondHeaderFallsBackToSeconds() throws {
        for value in ["invalid", "-100", "nan", "inf"] {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: JevConfiguration.defaultEndpoint)!, statusCode: 429, httpVersion: nil, headerFields: ["retry-after-ms": value, "Retry-After": "3"]))
            XCTAssertEqual(JevClassifier.retryAfter(from: response), 3)
        }
    }

    func testBackoffIsExponentialAndCapped() {
        let policy = JevRetryPolicy(jitter: 0)
        XCTAssertEqual(policy.delay(forRetry: 0, retryAfter: nil), 0.5)
        XCTAssertEqual(policy.delay(forRetry: 1, retryAfter: nil), 1)
        XCTAssertEqual(policy.delay(forRetry: 10, retryAfter: nil), 5)
        XCTAssertEqual(policy.delay(forRetry: 0, retryAfter: 120), 30)
    }

    func testDNSFailureIsFatal() {
        XCTAssertTrue(JevAPIError(URLError(.cannotFindHost)).isFatal)
        XCTAssertFalse(JevAPIError(URLError(.cannotFindHost)).isRetryable)
        XCTAssertTrue(JevAPIError(URLError(.timedOut)).isRetryable)
        XCTAssertFalse(JevAPIError(URLError(.timedOut)).isFatal)
    }

    // MARK: Eligibility

    func testEligibilitySkipsChildrenImagesEmptyAndSensitive() {
        let configuration = JevConfiguration()
        XCTAssertEqual(JevEligibility.skipReason(for: entry(.text, parent: UUID()), configuration: configuration), .extractedChild)
        XCTAssertEqual(JevEligibility.skipReason(for: entry(.image), configuration: configuration), .binaryContent)
        XCTAssertEqual(JevEligibility.skipReason(for: entry(.text, content: "  \n"), configuration: configuration), .emptyContent)
        XCTAssertEqual(JevEligibility.skipReason(for: entry(.apiKey), configuration: configuration), .sensitiveContent)
        XCTAssertNil(JevEligibility.skipReason(for: entry(.apiKey), configuration: JevConfiguration(includeSensitiveContent: true)))
        XCTAssertNil(JevEligibility.skipReason(for: entry(.url), configuration: configuration))
    }

    // MARK: Comparison

    func testReportExcludesFailuresAndSkipsFromAgreementStats() {
        let now = Date()
        let rows = [
            JevComparisonRow(id: UUID(), timestamp: now, sourceApp: nil, localCategory: .url, jevCategory: .url, confidence: 0.9, latency: 0.1),
            JevComparisonRow(id: UUID(), timestamp: now, sourceApp: nil, localCategory: .text, jevCategory: .prose, confidence: 0.7, latency: 0.3),
            JevComparisonRow(id: UUID(), timestamp: now, sourceApp: nil, localCategory: .text, error: "boom"),
            JevComparisonRow(id: UUID(), timestamp: now, sourceApp: nil, localCategory: .image, skipReason: .binaryContent)
        ]
        let report = JevComparisonReport(generatedAt: now, total: 4, rows: rows)

        XCTAssertEqual(report.compared, 2)
        XCTAssertEqual(report.agreements, 1)
        XCTAssertEqual(report.disagreements, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.agreementRate, 0.5)
        XCTAssertEqual(report.disagreementPairs, [JevCategoryPair(local: .text, jev: .prose, count: 1)])
        XCTAssertEqual(report.latencySummary?.median, 0.3)
    }

    func testCompareClassifiesSupportedEntriesAndRecordsSkips() async {
        JevMockURLProtocol.respond { request in
            let body = JevMockURLProtocol.bodyString(request)
            return (200, body.contains("https://example.com") ? Self.successBody(choice: "url") : Self.successBody(choice: "prose"))
        }
        let entries = [entry(.url, content: "https://example.com"), entry(.text, content: "hello"), entry(.image), entry(.apiKey)]

        let report = await JevComparisonService(classifier: makeClassifier(), maxConcurrentRequests: 2)
            .compare(entries: entries, configuration: JevConfiguration(), apiKey: "key")

        XCTAssertEqual(report.total, 4)
        XCTAssertEqual(report.compared, 2)
        XCTAssertEqual(report.agreements, 1)
        XCTAssertEqual(report.disagreements, 1)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(report.jevModels, ["jev-1.13.0"])
        XCTAssertNil(report.abortReason)
        XCTAssertEqual(JevMockURLProtocol.requests.count, 2)
    }

    func testCompareStopsOnFatalError() async {
        JevMockURLProtocol.respond { _ in (401, #"{"detail":"Invalid API key"}"#) }
        let entries = (0..<50).map { _ in entry(.text, content: "hello") }

        let report = await JevComparisonService(classifier: makeClassifier(), maxConcurrentRequests: 2)
            .compare(entries: entries, configuration: JevConfiguration(), apiKey: "bad")

        XCTAssertNotNil(report.abortReason)
        XCTAssertTrue(report.abortReason?.contains("401") == true)
        XCTAssertLessThanOrEqual(JevMockURLProtocol.requests.count, 2)
        XCTAssertEqual(report.rows.count, 50)
        XCTAssertGreaterThanOrEqual(report.rows.filter { $0.skipReason == .notAttempted }.count, 48)
        XCTAssertEqual(report.compared, 0)
    }

    func testCompareStopsAfterConsecutiveFailures() async {
        JevMockURLProtocol.respond { _ in (400, #"{"detail":"bad"}"#) }
        let entries = (0..<30).map { _ in entry(.text, content: "hello") }

        let report = await JevComparisonService(classifier: makeClassifier(), maxConcurrentRequests: 1, maxConsecutiveFailures: 3)
            .compare(entries: entries, configuration: JevConfiguration(), apiKey: "key")

        XCTAssertEqual(report.failed, 3)
        XCTAssertEqual(JevMockURLProtocol.requests.count, 3)
        XCTAssertTrue(report.abortReason?.contains("3 consecutive failures") == true)
    }

    func testCompareStopsImmediatelyOnValidationFailure() async {
        JevMockURLProtocol.respond { _ in (422, #"{"detail":"Unknown model"}"#) }
        let entries = (0..<30).map { _ in entry(.text, content: "hello") }

        let report = await JevComparisonService(classifier: makeClassifier(), maxConcurrentRequests: 1)
            .compare(entries: entries, configuration: JevConfiguration(model: "invalid"), apiKey: "key")

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(JevMockURLProtocol.requests.count, 1)
        XCTAssertTrue(report.abortReason?.contains("422") == true)
        XCTAssertEqual(report.rows.filter { $0.skipReason == .notAttempted }.count, 29)
    }

    func testCancellationStopsScheduling() async {
        JevMockURLProtocol.respond { _ in (200, Self.successBody(choice: "text")) }
        let entries = (0..<200).map { _ in entry(.text, content: "hello") }
        let classifier = makeClassifier()

        let task = Task {
            await JevComparisonService(classifier: classifier, maxConcurrentRequests: 1)
                .compare(entries: entries, configuration: JevConfiguration(), apiKey: "key")
        }
        task.cancel()
        let report = await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.rows.count, 200)
        XCTAssertLessThan(JevMockURLProtocol.requests.count, 200)
    }

    func testExportsExcludeContent() throws {
        let row = JevComparisonRow(id: UUID(), timestamp: Date(), sourceApp: "Notes, App", localCategory: .text, jevCategory: .prose, confidence: 0.5, latency: 0.25, jevModel: "jev-1.13.0", attempts: 1)
        let report = JevComparisonReport(generatedAt: Date(), endpointHost: "api.typesafe.ai", total: 1, rows: [row])

        let csv = report.csv()
        XCTAssertTrue(csv.hasPrefix("id,timestamp,source_app,outcome"))
        XCTAssertTrue(csv.contains("\"Notes, App\",disagreement,text,prose,prose,0.5000,250,jev-1.13.0,1"))
        let json = try XCTUnwrap(String(data: try report.jsonData(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"jevModel\" : \"jev-1.13.0\""))
        XCTAssertFalse(json.contains("content"))
    }

    // MARK: Helpers

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suiteName = "JevClassificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeClassifier(delays: DelayRecorder? = nil) -> JevClassifier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevMockURLProtocol.self]
        return JevClassifier(session: URLSession(configuration: configuration)) { seconds in
            await delays?.record(seconds)
        }
    }

    private func entry(_ type: ContentType, content: String = "value", parent: UUID? = nil) -> ClipboardEntry {
        ClipboardEntry(content: content, contentType: type, parentEntryId: parent)
    }

    private static func successBody(choice: String, confidence: Double = 0.8) -> String {
        """
        {"model":"jev-1.13.0","answers":{"content_type":{"type":"choice","choice":"\(choice)","probabilities":{"\(choice)":0.9,"unknown":0.1},"confidence":\(confidence)}},"usage":{"input_tokens":120,"output_tokens":1}}
        """
    }
}

private func XCTAssertThrowsJevError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (JevAPIError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch let error as JevAPIError {
        handler(error)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

final class JevMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, String)

    private static let lock = NSLock()
    private static var queue: [(status: Int, body: String, headers: [String: String])] = []
    private static var handler: Handler?
    private static var recordedRequests: [URLRequest] = []
    private static var recordedBodies: [Data] = []

    static var requests: [URLRequest] { lock.withLock { recordedRequests } }
    static var bodies: [Data] { lock.withLock { recordedBodies } }

    static func enqueue(status: Int, body: String, headers: [String: String] = [:]) {
        lock.withLock { queue.append((status, body, headers)) }
    }

    static func respond(_ newHandler: @escaping Handler) {
        lock.withLock { handler = newHandler }
    }

    static func reset() {
        lock.withLock {
            queue = []
            handler = nil
            recordedRequests = []
            recordedBodies = []
        }
    }

    static func bodyString(_ request: URLRequest) -> String {
        String(data: body(of: request), encoding: .utf8) ?? ""
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        var bodyRequest = request
        bodyRequest.httpBody = body
        let response: (status: Int, body: String, headers: [String: String]) = Self.lock.withLock {
            Self.recordedRequests.append(request)
            Self.recordedBodies.append(body)
            if !Self.queue.isEmpty { return Self.queue.removeFirst() }
            if let handler = Self.handler {
                let (status, text) = handler(bodyRequest)
                return (status, text, [:])
            }
            return (500, "{}", [:])
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
