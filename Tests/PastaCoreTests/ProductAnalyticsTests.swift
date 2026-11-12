import Foundation
import XCTest
@testable import PastaCore

final class ProductAnalyticsTests: XCTestCase {
    /// The sink is silent until consent reopens it, sends only bounded fields to
    /// the configured endpoint, retries queued events and purges what never left.
    func testTransportIsConsentGatedCarriesNoUserDataAndRetriesOrPurgesQueue() async throws {
        let recorder = RequestRecorder()
        let sink = makeSink(recorder: recorder)
        try await sink.capture(makePayload())
        XCTAssertEqual(recorder.requests.count, 0, "The sink must stay silent until reopen()")

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
        for key in ["content", "query", "source_app", "$ip"] {
            XCTAssertNil(properties[key], key)
        }

        // A failed send is queued and retried by the next sink on reopen.
        let queueURL = temporaryQueueURL()
        let firstSink = makeSink(queueURL: queueURL, recorder: RequestRecorder(statusCode: 500))
        try? await firstSink.reopen()
        try? await firstSink.capture(makePayload())
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
        let succeeding = RequestRecorder()
        try await makeSink(queueURL: queueURL, recorder: succeeding).reopen()
        XCTAssertEqual(succeeding.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))

        // Purge deletes queued events that never reached the server.
        let purgeURL = temporaryQueueURL()
        let failingSink = makeSink(queueURL: purgeURL, recorder: RequestRecorder(statusCode: 500))
        try? await failingSink.reopen()
        try? await failingSink.capture(makePayload())
        XCTAssertTrue(FileManager.default.fileExists(atPath: purgeURL.path))
        try await failingSink.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: purgeURL.path))
    }

    func testConsentLifecycleGatesEveryEventAndDeletesIdentityOnOptOut() async throws {
        let recorder = RequestRecorder()
        let (controller, store) = try makeController(recorder: recorder)

        try await controller.capture(.settingsOpened)
        let consent = await controller.consentState()
        XCTAssertEqual(consent, .unknown)
        XCTAssertEqual(recorder.requests.count, 0, "Nothing is sent until the user opts in")

        try await controller.setConsent(.optedIn)
        try await controller.capture(.settingsOpened)
        XCTAssertNotNil(try store.loadInstallationID())

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

        XCTAssertEqual(recorder.requests.compactMap(eventName(of:)).filter { $0 == "app_active_daily" }.count, 2)

        let countBeforeOptOut = recorder.requests.count
        try await controller.setConsent(.optedOut)
        XCTAssertNil(try store.loadInstallationID(), "Opting out must delete the install identity")
        XCTAssertEqual(try store.loadConsent(), .optedOut)
        // The opt-out event is sent before the queue is purged.
        XCTAssertEqual(recorder.requests.dropFirst(countBeforeOptOut).compactMap(eventName(of:)), ["analytics_opt_out"])

        let countAfterOptOut = recorder.requests.count
        try await controller.capture(.pastePerformed(contentType: .text))
        try await controller.capture(.searchPerformed(hasFilter: true))
        XCTAssertEqual(recorder.requests.count, countAfterOptOut)

        // The `PASTA_CI` kill switch: an opted-in controller still sends nothing.
        let ciRecorder = RequestRecorder()
        let (ciController, _) = try makeController(recorder: ciRecorder, forceDisabled: true)
        try await ciController.setConsent(.optedIn)
        try await ciController.capture(.appActiveDaily)
        try await ciController.captureDailyActiveIfNeeded()
        XCTAssertEqual(ciRecorder.requests.count, 0)
    }

    /// The "silent no-op" guarantee for unconfigured builds, plus the payload
    /// boundary: every context and event value is normalised to a bounded set.
    func testConfigurationAndPayloadBoundary() throws {
        let resolve = QueuedCaptureAnalyticsSink.Configuration.resolve
        XCTAssertNil(resolve([:], { _ in nil }), "No key anywhere")
        XCTAssertNil(resolve([:], { $0 == "PostHogProjectKey" ? "" : nil }), "Empty Info.plist key")
        XCTAssertNil(resolve([:], { $0 == "PostHogProjectKey" ? "   " : nil }),
                     "Whitespace-only key (an unsubstituted CI secret)")
        XCTAssertNil(resolve(["POSTHOG_PROJECT_KEY": ""], { _ in nil }), "Empty environment key")
        let configuration = try XCTUnwrap(resolve([:], { $0 == "PostHogProjectKey" ? "phc_live" : nil }))
        XCTAssertEqual(configuration.projectKey, "phc_live")
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://eu.i.posthog.com/capture")

        let junk = ProductAnalyticsContext(
            appVersion: "1.2.3-beta+deadbeef", build: "unstable", osMajorMinor: "26.0.1",
            distributionChannel: .direct, localeLanguageCode: "zz-ZZ-somewhere", architecture: "ppc"
        )
        XCTAssertEqual([junk.appVersion, junk.build, junk.osMajorMinor, junk.architecture],
                       ["other", "other", "other", "other"])
        // A two-letter subtag is kept even when the rest is junk; region is dropped on purpose.
        for (language, expected) in [("zz-ZZ-somewhere", "zz"), ("klingon", "other"), ("en_GB", "en"), ("en-US", "en")] {
            XCTAssertEqual(makeContext(language: language).localeLanguageCode, expected, "case \(language)")
        }
        let valid = ProductAnalyticsContext(
            appVersion: "1.2.3", build: "42", osMajorMinor: "26.0",
            distributionChannel: .direct, localeLanguageCode: "fr", architecture: "ARM64"
        )
        XCTAssertEqual([valid.appVersion, valid.build, valid.osMajorMinor, valid.architecture],
                       ["1.2.3", "42", "26.0", "arm64"])

        let allowed = Set(["true", "false"] + ContentType.allCases.map(\.rawValue))
        let events: [ProductAnalyticsEvent] = [
            .appActiveDaily, .analyticsOptIn, .analyticsOptOut, .settingsOpened,
            .searchPerformed(hasFilter: true), .searchPerformed(hasFilter: false)
        ] + ContentType.allCases.map { .pastePerformed(contentType: $0) }
        for event in events {
            for (key, value) in event.properties {
                XCTAssertTrue(allowed.contains(value), "Event \(event.name) property \(key) has unbounded value \(value)")
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
