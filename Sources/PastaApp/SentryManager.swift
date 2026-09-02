import Foundation
import Sentry

/// Manages Sentry crash reporting and error tracking.
///
/// Pasta is a privacy-first clipboard manager, so crash reporting is **opt-in**:
/// the SDK is only initialized when the user has explicitly enabled it via
/// the General settings tab (UserDefaults key `pasta.crashReportingEnabled`).
/// Until then, every entry point is a no-op.
enum SentryManager {
    /// UserDefaults key that gates whether the Sentry SDK is initialized at all.
    /// Defaults to `false` (opt-in).
    static let enabledDefaultsKey = "pasta.crashReportingEnabled"

    /// Whether the user has opted in to crash reporting.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    /// Initialize Sentry SDK - call as early as possible in app lifecycle.
    /// No-op unless the user has opted in via settings, and also no-op in DEBUG builds.
    static func start() {
        #if DEBUG
        // Don't send errors in debug builds
        return
        #else
        guard isEnabled else { return }
        SentrySDK.start { options in
            options.dsn = "https://ba04b3c3ce2e5249bc5cf50832c885e7@o4510682832240640.ingest.de.sentry.io/4510790604488784"
            
            // Enable performance monitoring
            options.tracesSampleRate = 0.2  // 20% of transactions
            
            // Attach stack traces to all events
            options.attachStacktrace = true
            
            // Enable automatic breadcrumbs
            options.enableAutoBreadcrumbTracking = true
            
            // Capture HTTP client errors
            options.enableCaptureFailedRequests = true
            
            // Set environment
            options.environment = "production"
            
            // Set app version from bundle
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                options.releaseName = "com.pasta.clipboard@\(version)+\(build)"
            }
            
            // Don't send PII by default
            options.sendDefaultPii = false
        }
        #endif
    }
    
    /// Capture an error with optional context
    static func capture(error: Error, context: [String: Any]? = nil) {
        #if !DEBUG
        guard isEnabled else { return }
        SentrySDK.capture(error: error) { scope in
            if let context = context {
                scope.setContext(value: context, key: "custom")
            }
        }
        #endif
    }

    /// Capture a message for non-error events
    static func capture(message: String, level: SentryLevel = .info) {
        #if !DEBUG
        guard isEnabled else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
        #endif
    }

    /// Add breadcrumb for debugging context
    static func addBreadcrumb(category: String, message: String, level: SentryLevel = .info) {
        #if !DEBUG
        guard isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    /// Set user identifier (anonymized)
    static func setUser(id: String) {
        #if !DEBUG
        guard isEnabled else { return }
        let user = User(userId: id)
        SentrySDK.setUser(user)
        #endif
    }
}
