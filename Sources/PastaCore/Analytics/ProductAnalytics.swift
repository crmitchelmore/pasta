// The event catalogue, the payload boundary and the consent controller live together
// so Pasta's analytics privacy contract can be audited as a single unit.
//
// Privacy rules (enforced by the types below, not by convention):
//   * Every property is an enum raw value, a boolean or a bounded version string.
//     There is no way to attach a free-form string to an event.
//   * Clipboard contents, search queries, file paths, app names and any other
//     user data are structurally impossible to send — no event carries them.
//   * The only identifier is a random UUID minted on opt-in and deleted on opt-out.
import Foundation

/// Whether the user has agreed to anonymous product analytics.
///
/// `unknown` is the fail-closed default: collection only ever happens in `optedIn`.
public enum AnalyticsConsentState: String, Codable, CaseIterable, Sendable {
    case unknown
    case optedIn
    case optedOut

    public var permitsCollection: Bool { self == .optedIn }
}

/// How this copy of Pasta was installed. Bounded to a closed set so it can never
/// carry a path or other machine-identifying string.
public enum AnalyticsDistributionChannel: String, Codable, Sendable {
    /// A signed release build (the DMG, including the Homebrew cask, which ships the same binary).
    case direct
    case development
}

/// The complete set of events Pasta is allowed to send.
///
/// Adding a case here is the only way to add an event, and each case's
/// `properties` are restricted to enum raw values and booleans.
public enum ProductAnalyticsEvent: Sendable, Equatable {
    /// Sent at most once per calendar day while the app is running.
    case appActiveDaily
    /// Sent immediately after the user turns analytics on.
    case analyticsOptIn
    /// Sent immediately *before* the queue is purged when the user turns analytics off.
    case analyticsOptOut
    /// A clipboard entry was pasted. Carries the detected content type only — never the content.
    case pastePerformed(contentType: ContentType)
    /// A search was run. Carries whether a filter was active — never the query text.
    case searchPerformed(hasFilter: Bool)
    /// The settings window was opened.
    case settingsOpened

    public var name: String {
        switch self {
        case .appActiveDaily: return "app_active_daily"
        case .analyticsOptIn: return "analytics_opt_in"
        case .analyticsOptOut: return "analytics_opt_out"
        case .pastePerformed: return "paste_performed"
        case .searchPerformed: return "search_performed"
        case .settingsOpened: return "settings_opened"
        }
    }

    public var properties: [String: String] {
        switch self {
        case .appActiveDaily, .analyticsOptIn, .analyticsOptOut, .settingsOpened:
            return [:]
        case .pastePerformed(let contentType):
            return ["content_type": contentType.rawValue]
        case .searchPerformed(let hasFilter):
            return ["has_filter": String(hasFilter)]
        }
    }
}

/// The environment properties attached to every event.
///
/// Every field is normalised on the way in: anything that does not match the
/// expected shape collapses to `"other"`, so a hand-edited Info.plist or an
/// unusual locale can never turn into a high-cardinality identifier.
public struct ProductAnalyticsContext: Equatable, Sendable {
    public static let schemaVersion = 1

    public let appVersion: String
    public let build: String
    public let osMajorMinor: String
    public let distributionChannel: AnalyticsDistributionChannel
    public let localeLanguageCode: String
    public let architecture: String

    public init(
        appVersion: String,
        build: String,
        osMajorMinor: String,
        distributionChannel: AnalyticsDistributionChannel,
        localeLanguageCode: String,
        architecture: String
    ) {
        self.appVersion = Self.boundedVersion(appVersion)
        self.build = Self.boundedDecimal(build, maximumLength: 12)
        self.osMajorMinor = Self.boundedOSVersion(osMajorMinor)
        self.distributionChannel = distributionChannel
        self.localeLanguageCode = Self.boundedLanguageCode(localeLanguageCode)
        self.architecture = Self.boundedArchitecture(architecture)
    }

    /// Up to four dot-separated numeric components (`1`, `1.0`, `1.0.0`, `1.0.0.1`).
    private static func boundedVersion(_ value: String) -> String {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count),
              components.allSatisfy({ isDecimal($0, maximumLength: 5) })
        else { return "other" }
        return value
    }

    private static func boundedDecimal(_ value: String, maximumLength: Int) -> String {
        isDecimal(value[...], maximumLength: maximumLength) ? value : "other"
    }

    private static func boundedOSVersion(_ value: String) -> String {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ isDecimal($0, maximumLength: 3) })
        else { return "other" }
        return value
    }

    /// Two- or three-letter ISO 639 language subtag, lowercased. Region is dropped
    /// on purpose: `en-GB` and `en-US` both report `en`.
    private static func boundedLanguageCode(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let language = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        guard (2...3).contains(language.count),
              language.unicodeScalars.allSatisfy({ ("a"..."z").contains(Character($0)) })
        else { return "other" }
        return language
    }

    private static func boundedArchitecture(_ value: String) -> String {
        let normalized = value.lowercased()
        return ["arm64", "x86_64"].contains(normalized) ? normalized : "other"
    }

    private static func isDecimal(_ value: Substring, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { (48...57).contains(Int($0.value)) }
    }
}

/// The single, audited shape of everything that can leave the machine.
public struct ProductAnalyticsPayload: Encodable, Equatable, Sendable {
    public let event: String
    /// A random per-install UUID. Not derived from anything about the user or device.
    public let distinctID: UUID
    public let properties: [String: String]

    public init(event: ProductAnalyticsEvent, context: ProductAnalyticsContext, distinctID: UUID) {
        self.event = event.name
        self.distinctID = distinctID
        self.properties = event.properties.merging([
            "platform": "macOS",
            "app_version": context.appVersion,
            "build": context.build,
            "os_major_minor": context.osMajorMinor,
            "distribution_channel": context.distributionChannel.rawValue,
            "locale_language_code": context.localeLanguageCode,
            "architecture": context.architecture,
            "analytics_schema_version": String(ProductAnalyticsContext.schemaVersion)
        ]) { eventValue, _ in eventValue }
    }
}

/// Transport boundary. `reopen` is the only thing that ever permits a network call.
public protocol ProductAnalyticsSink: Sendable {
    func reopen() async throws
    func capture(_ payload: ProductAnalyticsPayload) async throws
    func purge() async throws
    func close() async
}

/// Consent, install identity and the once-per-day marker.
public protocol ProductAnalyticsStateStore: Sendable {
    func loadConsent() throws -> AnalyticsConsentState
    func saveConsent(_ consent: AnalyticsConsentState) throws
    func loadInstallationID() throws -> UUID?
    func saveInstallationID(_ id: UUID) throws
    func deleteInstallationID() throws
    func loadLastDailyActiveDay() throws -> Date?
    func saveLastDailyActiveDay(_ day: Date) throws
}

/// Owns consent and is the only thing that may hand a payload to the sink.
public actor ProductAnalyticsController {
    private let context: ProductAnalyticsContext
    private let sink: any ProductAnalyticsSink
    private let stateStore: any ProductAnalyticsStateStore
    /// Kill switch evaluated on every capture (used for `PASTA_CI`).
    private let forceDisabled: @Sendable () -> Bool
    private var consent: AnalyticsConsentState

    public init(
        context: ProductAnalyticsContext,
        sink: any ProductAnalyticsSink,
        stateStore: any ProductAnalyticsStateStore,
        forceDisabled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        self.context = context
        self.sink = sink
        self.stateStore = stateStore
        self.forceDisabled = forceDisabled
        self.consent = try stateStore.loadConsent()
    }

    public func consentState() -> AnalyticsConsentState { consent }

    /// Applies a consent transition fail-closed.
    ///
    /// Opting in persists consent *before* the sink is allowed to open. Opting out
    /// sends the final `analytics_opt_out` event while consent still permits it, then
    /// purges the queue and deletes the install identity — every cleanup step is
    /// attempted even if an earlier one throws.
    public func setConsent(_ newConsent: AnalyticsConsentState) async throws {
        guard newConsent != consent || newConsent == .optedIn else { return }

        if newConsent == .optedIn {
            try stateStore.saveConsent(newConsent)
            consent = newConsent
            guard !forceDisabled() else {
                try await suspendCollection()
                return
            }
            try await sink.reopen()
            return
        }

        // Opt-out: last event first, then destroy everything.
        if consent.permitsCollection, !forceDisabled() {
            try? await sink.capture(
                ProductAnalyticsPayload(event: .analyticsOptOut, context: context, distinctID: try installationID())
            )
        }
        consent = newConsent
        var firstFailure: Error?
        do { try stateStore.saveConsent(newConsent) } catch { firstFailure = error }
        do { try await suspendCollection() } catch { firstFailure = firstFailure ?? error }
        if let firstFailure { throw firstFailure }
    }

    public func capture(_ event: ProductAnalyticsEvent) async throws {
        guard consent.permitsCollection else { return }
        guard !forceDisabled() else {
            try await suspendCollection()
            return
        }
        try await sink.capture(
            ProductAnalyticsPayload(event: event, context: context, distinctID: try installationID())
        )
    }

    /// Sends `app_active_daily` at most once per calendar day in the given calendar.
    @discardableResult
    public func captureDailyActiveIfNeeded(
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> Bool {
        guard consent.permitsCollection, !forceDisabled() else { return false }
        let today = calendar.startOfDay(for: now)
        if let last = try stateStore.loadLastDailyActiveDay(), calendar.isDate(last, inSameDayAs: today) {
            return false
        }
        try await capture(.appActiveDaily)
        try stateStore.saveLastDailyActiveDay(today)
        return true
    }


    private func installationID() throws -> UUID {
        if let existing = try stateStore.loadInstallationID() { return existing }
        let id = UUID()
        try stateStore.saveInstallationID(id)
        return id
    }

    private func suspendCollection() async throws {
        var firstFailure: Error?
        do { try await sink.purge() } catch { firstFailure = error }
        do { try stateStore.deleteInstallationID() } catch { firstFailure = firstFailure ?? error }
        await sink.close()
        if let firstFailure { throw firstFailure }
    }
}
