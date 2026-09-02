import Foundation
import XCTest
@testable import PastaCore

final class ProductAnalyticsTests: XCTestCase {
    // MARK: - Transport

    func testNothingIsSentBeforeConsentReopensTheSink() async throws {
        let recorder = RequestRecorder()
        let sink = makeSink(recorder: recorder)

        try await sink.capture(makePayload())

        XCTAssertEqual(recorder.requests.count, 0, "The sink must stay silent until reopen()")
    }

    func testCaptureUsesOnlyTheConfiguredEndpointAndCarriesNoUserData() async throws {
        let recorder = RequestRecorder()
        let sink = makeSink(recorder: recorder)
        try await sink.reopen()

        try await sink.capture(makePayload(event: .pastePerformed(contentType: .apiKey)))

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://eu.i.posthog.com/capture")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["api_key"] as? String, "phc_test")
        XCTAssertEqual(body["event"] as? String, "paste_performed")
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(properties["content_type"] as? String, "apiKey")
        XCTAssertEqual(properties["platform"] as? String, "macOS")
        XCTAssertEqual(properties["locale_language_code"] as? String, "en")
        // The content type is a bounded enum; the content itself has no key at all.
        XCTAssertNil(properties["content"])
        XCTAssertNil(properties["query"])
        XCTAssertNil(properties["source_app"])
        XCTAssertNil(properties["$ip"])
    }

    func testPurgeDeletesQueuedEventsThatNeverReachedTheServer() async throws {
        let queueURL = temporaryQueueURL()
        let sink = makeSink(queueURL: queueURL, recorder: RequestRecorder(statusCode: 500))
        try? await sink.reopen()
        try? await sink.capture(makePayload())
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))

        try await sink.purge()

        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    func testQueuedEventsAreRetriedOnTheNextReopen() async throws {
        let queueURL = temporaryQueueURL()
        let failing = RequestRecorder(statusCode: 500)
        let firstSink = makeSink(queueURL: queueURL, recorder: failing)
        try? await firstSink.reopen()
        try? await firstSink.capture(makePayload())

        let succeeding = RequestRecorder()
        let secondSink = makeSink(queueURL: queueURL, recorder: succeeding)
        try await secondSink.reopen()

        XCTAssertEqual(succeeding.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    }

    // MARK: - Consent

    func testControllerSendsNothingUntilTheUserOptsIn() async throws {
        let recorder = RequestRecorder()
        let (controller, _) = try makeController(recorder: recorder)

        try await controller.capture(.settingsOpened)

        let consent = await controller.consentState()
        XCTAssertEqual(consent, .unknown)
        XCTAssertEqual(recorder.requests.count, 0)
    }

    func testOptInMintsARandomInstallIDAndOptOutDeletesIt() async throws {
        let recorder = RequestRecorder()
        let (controller, store) = try makeController(recorder: recorder)

        try await controller.setConsent(.optedIn)
        try await controller.capture(.settingsOpened)
        let installID = try store.loadInstallationID()
        XCTAssertNotNil(installID)

        try await controller.setConsent(.optedOut)

        XCTAssertNil(try store.loadInstallationID(), "Opting out must delete the install identity")
        XCTAssertEqual(try store.loadConsent(), .optedOut)
    }

    func testOptOutEventIsSentBeforeTheQueueIsPurged() async throws {
        let recorder = RequestRecorder()
        let (controller, _) = try makeController(recorder: recorder)
        try await controller.setConsent(.optedIn)

        try await controller.setConsent(.optedOut)

        let events = recorder.requests.compactMap(eventName(of:))
        XCTAssertEqual(events, ["analytics_opt_out"])
    }

    func testCaptureAfterOptOutSendsNothing() async throws {
        let recorder = RequestRecorder()
        let (controller, _) = try makeController(recorder: recorder)
        try await controller.setConsent(.optedIn)
        try await controller.setConsent(.optedOut)
        let countAfterOptOut = recorder.requests.count

        try await controller.capture(.pastePerformed(contentType: .text))
        try await controller.capture(.searchPerformed(hasFilter: true))

        XCTAssertEqual(recorder.requests.count, countAfterOptOut)
    }

    /// Proves the `PASTA_CI` kill switch: with `forceDisabled` true, an opted-in
    /// controller still performs zero requests.
    func testForceDisabledSuppressesEverythingEvenWhenOptedIn() async throws {
        let recorder = RequestRecorder()
        let (controller, _) = try makeController(recorder: recorder, forceDisabled: true)

        try await controller.setConsent(.optedIn)
        try await controller.capture(.appActiveDaily)
        try await controller.captureDailyActiveIfNeeded()

        XCTAssertEqual(recorder.requests.count, 0)
    }

    func testAppActiveDailyIsSentOncePerCalendarDay() async throws {
        let recorder = RequestRecorder()
        let (controller, _) = try makeController(recorder: recorder)
        try await controller.setConsent(.optedIn)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try await controller.captureDailyActiveIfNeeded(now: day, calendar: calendar)
        let sameDay = try await controller.captureDailyActiveIfNeeded(
            now: day.addingTimeInterval(6 * 60 * 60), calendar: calendar
        )
        let nextDay = try await controller.captureDailyActiveIfNeeded(
            now: day.addingTimeInterval(30 * 60 * 60), calendar: calendar
        )

        XCTAssertTrue(first)
        XCTAssertFalse(sameDay)
        XCTAssertTrue(nextDay)
        XCTAssertEqual(recorder.requests.compactMap(eventName(of:)), ["app_active_daily", "app_active_daily"])
    }

    // MARK: - Configuration

    /// The "silent no-op" guarantee: an unconfigured build resolves no destination,
    /// so `AnalyticsManager.start()` returns before it allocates a sink or a state file.
    func testNoConfigurationWithoutAProjectKey() {
        let resolve = QueuedCaptureAnalyticsSink.Configuration.resolve

        XCTAssertNil(resolve([:], { _ in nil }), "No key anywhere")
        XCTAssertNil(resolve([:], { $0 == "PostHogProjectKey" ? "" : nil }), "Empty Info.plist key")
        XCTAssertNil(
            resolve([:], { $0 == "PostHogProjectKey" ? "   " : nil }),
            "Whitespace-only key (an unsubstituted CI secret)"
        )
        XCTAssertNil(resolve(["POSTHOG_PROJECT_KEY": ""], { _ in nil }), "Empty environment key")
    }

    func testConfigurationDefaultsToTheEUCaptureEndpoint() throws {
        let configuration = try XCTUnwrap(
            QueuedCaptureAnalyticsSink.Configuration.resolve(
                environment: [:],
                infoValue: { $0 == "PostHogProjectKey" ? "phc_live" : nil }
            )
        )
        XCTAssertEqual(configuration.projectKey, "phc_live")
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://eu.i.posthog.com/capture")
    }

    // MARK: - Payload boundary

    func testContextNormalisesUnexpectedValuesToOther() {
        let context = ProductAnalyticsContext(
            appVersion: "1.2.3-beta+deadbeef",
            build: "unstable",
            osMajorMinor: "26.0.1",
            distributionChannel: .direct,
            localeLanguageCode: "zz-ZZ-somewhere",
            architecture: "ppc"
        )

        XCTAssertEqual(context.appVersion, "other")
        XCTAssertEqual(context.build, "other")
        XCTAssertEqual(context.osMajorMinor, "other")
        XCTAssertEqual(context.architecture, "other")
        // A two-letter subtag is kept even when the rest is junk; anything longer collapses.
        XCTAssertEqual(context.localeLanguageCode, "zz")
        XCTAssertEqual(makeContext(language: "klingon").localeLanguageCode, "other")

        // Region is dropped on purpose: en-GB and en-US are indistinguishable.
        XCTAssertEqual(makeContext(language: "en_GB").localeLanguageCode, "en")
        XCTAssertEqual(makeContext(language: "en-US").localeLanguageCode, "en")

        let valid = ProductAnalyticsContext(
            appVersion: "1.2.3", build: "42", osMajorMinor: "26.0",
            distributionChannel: .direct, localeLanguageCode: "fr", architecture: "ARM64"
        )
        XCTAssertEqual(valid.appVersion, "1.2.3")
        XCTAssertEqual(valid.build, "42")
        XCTAssertEqual(valid.osMajorMinor, "26.0")
        XCTAssertEqual(valid.architecture, "arm64")
    }

    func testEveryEventPropertyIsABoundedEnumOrBoolean() {
        let allowed = Set(["true", "false"] + ContentType.allCases.map(\.rawValue))
        let events: [ProductAnalyticsEvent] = [
            .appActiveDaily, .analyticsOptIn, .analyticsOptOut, .settingsOpened,
            .searchPerformed(hasFilter: true), .searchPerformed(hasFilter: false)
        ] + ContentType.allCases.map { .pastePerformed(contentType: $0) }

        for event in events {
            for (key, value) in event.properties {
                XCTAssertTrue(
                    allowed.contains(value),
                    "Event \(event.name) property \(key) has unbounded value \(value)"
                )
            }
        }
    }

    // MARK: - Helpers

    private func makeSink(
        queueURL: URL? = nil,
        recorder: RequestRecorder
    ) -> QueuedCaptureAnalyticsSink {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        RecordingURLProtocol.recorder = recorder
        return QueuedCaptureAnalyticsSink(
            configuration: .init(
                projectKey: "phc_test",
                endpoint: URL(string: "https://eu.i.posthog.com/capture")!
            ),
            queueURL: queueURL ?? temporaryQueueURL(),
            session: URLSession(configuration: configuration)
        )
    }

    private func makeController(
        recorder: RequestRecorder,
        forceDisabled: Bool = false
    ) throws -> (ProductAnalyticsController, FileProductAnalyticsStateStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = FileProductAnalyticsStateStore(
            fileURL: directory.appendingPathComponent("analytics_state.json")
        )
        let controller = try ProductAnalyticsController(
            context: makeContext(),
            sink: makeSink(queueURL: directory.appendingPathComponent("queue.json"), recorder: recorder),
            stateStore: store,
            forceDisabled: { forceDisabled }
        )
        return (controller, store)
    }

    private func makeContext(language: String = "en") -> ProductAnalyticsContext {
        ProductAnalyticsContext(
            appVersion: "1.0.0",
            build: "42",
            osMajorMinor: "26.0",
            distributionChannel: .direct,
            localeLanguageCode: language,
            architecture: "arm64"
        )
    }

    private func makePayload(event: ProductAnalyticsEvent = .appActiveDaily) -> ProductAnalyticsPayload {
        ProductAnalyticsPayload(event: event, context: makeContext(), distinctID: UUID())
    }

    private func eventName(of request: URLRequest) -> String? {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return json["event"] as? String
    }

    private func temporaryQueueURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("analytics_queue.json")
    }
}

// MARK: - Recording URLProtocol

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    let statusCode: Int

    init(statusCode: Int = 200) { self.statusCode = statusCode }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storedRequests
    }

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        storedRequests.append(request)
    }
}

/// Records every request instead of letting it hit the network, so the test suite
/// makes no outbound calls.
private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder: RequestRecorder?

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = Self.recorder, let url = request.url else { return }
        var recorded = request
        // URLSession moves small bodies into a stream; read it back so assertions can see it.
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            recorded.httpBody = data
        }
        recorder.append(recorded)
        let response = HTTPURLResponse(
            url: url, statusCode: recorder.statusCode, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
