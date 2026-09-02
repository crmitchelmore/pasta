import Foundation

import PastaCore

/// Opt-in, privacy-first product analytics.
///
/// Pasta is a clipboard manager, so analytics are **off by default** and stay off
/// until the user turns them on in Settings → General → Diagnostics
/// (UserDefaults key `pasta.analyticsEnabled`). Until then — and always when no
/// project key is configured, or when running under `PASTA_CI` — every entry point
/// here is a silent no-op that opens no files and makes no network calls.
///
/// What is sent: event names from `ProductAnalyticsEvent`, the app version and
/// build, the macOS major.minor version, the distribution channel, the locale
/// *language* (not region), the CPU architecture, and a random UUID minted on
/// opt-in and deleted on opt-out. What is never sent: clipboard contents, search
/// queries, app names, file paths, or anything identifying the user or machine.
final class AnalyticsManager: @unchecked Sendable {
    static let shared = AnalyticsManager()

    /// UserDefaults key that gates collection. Defaults to `false` (opt-in).
    static let enabledDefaultsKey = "pasta.analyticsEnabled"

    private let lock = NSLock()
    private var controller: ProductAnalyticsController?
    private var consentObserver: NSObjectProtocol?
    private var lastKnownEnabled = false

    private init() {}

    /// Whether the user has opted in to analytics.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Wires up analytics. Call once from `applicationDidFinishLaunching`.
    ///
    /// Returns without allocating anything when analytics cannot run at all, so an
    /// unconfigured build (no `PostHogProjectKey`) and CI are provably inert.
    func start() {
        guard !AnalyticsEnvironment.isSuppressedByEnvironment else {
            PastaLogger.app.debug("Analytics disabled: PASTA_CI is set")
            return
        }
        guard let configuration = AnalyticsEnvironment.resolveConfiguration() else {
            PastaLogger.app.debug("Analytics disabled: no project key configured")
            return
        }

        let directory = AnalyticsEnvironment.supportDirectory
        let stateStore = FileProductAnalyticsStateStore(
            fileURL: directory.appendingPathComponent("analytics_state.json")
        )
        let sink = QueuedCaptureAnalyticsSink(
            configuration: configuration,
            queueURL: directory.appendingPathComponent("analytics_queue.json")
        )
        guard let controller = try? ProductAnalyticsController(
            context: AnalyticsEnvironment.buildContext(),
            sink: sink,
            stateStore: stateStore,
            // Re-checked on every capture so a CI-shaped environment can never leak.
            forceDisabled: { AnalyticsEnvironment.isSuppressedByEnvironment }
        ) else { return }

        let enabled = Self.isEnabled
        lock.lock()
        self.controller = controller
        self.lastKnownEnabled = enabled
        lock.unlock()

        Task {
            try? await controller.setConsent(enabled ? .optedIn : .optedOut)
            _ = try? await controller.captureDailyActiveIfNeeded()
        }
        observeConsentChanges()
    }

    /// Records an event. No-op unless analytics are configured and the user opted in.
    func capture(_ event: ProductAnalyticsEvent) {
        lock.lock()
        let controller = self.controller
        lock.unlock()
        guard let controller else { return }
        Task { try? await controller.capture(event) }
    }

    /// Applies toggle changes without an app restart.
    ///
    /// `UserDefaults.didChangeNotification` fires for every defaults write in the
    /// app, so the handler only acts when the analytics flag actually flipped.
    private func observeConsentChanges() {
        guard consentObserver == nil else { return }
        consentObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let enabled = Self.isEnabled
            self.lock.lock()
            let changed = enabled != self.lastKnownEnabled
            let controller = self.controller
            if changed { self.lastKnownEnabled = enabled }
            self.lock.unlock()
            guard changed, let controller else { return }
            Task {
                // `setConsent` sends `analytics_opt_out` before purging on the way out.
                try? await controller.setConsent(enabled ? .optedIn : .optedOut)
                if enabled {
                    try? await controller.capture(.analyticsOptIn)
                    _ = try? await controller.captureDailyActiveIfNeeded()
                }
            }
        }
    }
}
