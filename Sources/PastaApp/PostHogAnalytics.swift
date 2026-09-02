import Foundation

import PastaCore

/// Resolves the analytics destination and environment context.
///
/// The project key is a *public* PostHog ingestion key (write-only, safe to ship in
/// a client). It is injected at bundle time into `Info.plist` as `PostHogProjectKey`
/// from the repository secret `POSTHOG_PROJECT_KEY`. Local and unreleased builds
/// have no key, so `resolveConfiguration()` returns `nil` and analytics never runs.
enum AnalyticsEnvironment {
    /// `PASTA_CI` is set by the CI launch smoke test. Analytics must never make a
    /// network call there, even if a key somehow ends up in the bundle.
    static var isSuppressedByEnvironment: Bool {
        ProcessInfo.processInfo.environment["PASTA_CI"] != nil
    }

    /// Resolution itself lives in `PastaCore` so the "no key ⇒ no analytics" rule is
    /// covered by `ProductAnalyticsTests`.
    static func resolveConfiguration(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> QueuedCaptureAnalyticsSink.Configuration? {
        QueuedCaptureAnalyticsSink.Configuration.resolve(environment: environment) {
            bundle.object(forInfoDictionaryKey: $0) as? String
        }
    }

    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Pasta", isDirectory: true)
    }

    static func buildContext(bundle: Bundle = .main) -> ProductAnalyticsContext {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        #if DEBUG
        let channel = AnalyticsDistributionChannel.development
        #else
        let channel = AnalyticsDistributionChannel.direct
        #endif
        return ProductAnalyticsContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "other",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "other",
            osMajorMinor: "\(osVersion.majorVersion).\(osVersion.minorVersion)",
            distributionChannel: channel,
            localeLanguageCode: Locale.current.language.languageCode?.identifier ?? "other",
            architecture: architecture
        )
    }
}
