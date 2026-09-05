import AppKit
import Foundation

import PastaCore

/// Launch-readiness signalling for the CI smoke test. Every entry point is a
/// no-op unless `PASTA_CI` is set (the same switch that disables CloudKit and
/// analytics), so shipping builds never write markers or change how they quit.
///
/// The smoke test used to check only that the PID was still alive five
/// seconds after launch, which passes for a process wedged before its
/// database opened. Now `BackgroundService` calls `signal` once the initial
/// history load has come back from durable storage AND clipboard monitoring is
/// running, without an in-memory database or temporary image-storage fallback;
/// CI waits for that, then sends SIGTERM and asserts exit code 0.
enum CIReadiness {
    /// Reuses the process-wide `PASTA_CI` check so there is one definition.
    static var isEnabled: Bool { AnalyticsEnvironment.isSuppressedByEnvironment }

    /// Path of the marker file to write, if the harness wants one in addition
    /// to the stderr line.
    static let markerFileEnvironmentKey = "PASTA_CI_READY_FILE"

    /// Prefix of the stderr line the harness greps for.
    static let readyLine = "PASTA_CI_READY"

    private static var terminationSource: DispatchSourceSignal?

    /// Writes `PASTA_CI_READY entries=<n>` to stderr and to the marker file
    /// named by `PASTA_CI_READY_FILE` (when set).
    static func signal(entryCount: Int) {
        guard isEnabled else { return }
        let line = "\(readyLine) entries=\(entryCount)\n"
        FileHandle.standardError.write(Data(line.utf8))

        if let path = ProcessInfo.processInfo.environment[markerFileEnvironmentKey], !path.isEmpty {
            do {
                try line.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                PastaLogger.app.error("Failed to write CI readiness marker to \(path): \(error.localizedDescription)")
            }
        }
        PastaLogger.app.info("CI readiness signalled (\(entryCount) entries loaded)")
    }

    /// Prefix of the stderr line the harness treats as an immediate failure.
    static let degradedLine = "PASTA_CI_DEGRADED"

    /// Reports that readiness will never be signalled because a persistent
    /// service fell back to volatile storage (in-memory database, temporary
    /// image directory). Without this line the smoke test could only time out
    /// with a generic message; with it, scripts/ci-launch-smoke.sh fails fast
    /// and names the reason. Stderr is the only channel the harness captures.
    static func reportDegraded(reason: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("\(degradedLine) reason=\(reason)\n".utf8))
        PastaLogger.app.error("CI readiness refused: \(reason)")
    }

    /// Routes SIGTERM through `NSApplication.terminate` so the harness's
    /// `kill -TERM` exercises the normal quit path (and gets exit code 0)
    /// instead of the default signal death (exit 143) that would hide a
    /// crash-on-quit.
    @MainActor
    static func installGracefulTerminationHandler() {
        guard isEnabled, terminationSource == nil else { return }
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Mirrored on stderr so the CI log shows the quit was attempted.
            FileHandle.standardError.write(Data("PASTA_CI_TERMINATING\n".utf8))
            PastaLogger.app.info("SIGTERM received under PASTA_CI; terminating gracefully")

            // No sheet/modal dismissal here on purpose: AppKit silently refuses
            // `terminate:` while a sheet is attached, and first-launch
            // onboarding is exactly what a fresh CI runner shows. Onboarding is
            // therefore presented as its own window (OnboardingWindowController),
            // and this smoke path is the regression test that quitting works
            // while it is on screen (pasta-adt). If a sheet ever creeps back,
            // PASTA_CI_TERMINATE_REFUSED below fails the run loudly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.terminate(nil)
                // `terminate(_:)` only returns when AppKit refused to quit; make
                // that visible in the CI stderr log rather than a bare timeout.
                FileHandle.standardError.write(Data("PASTA_CI_TERMINATE_REFUSED\n".utf8))
                FileHandle.standardError.write(Data(windowStateDescription().utf8))
                PastaLogger.app.error("NSApplication.terminate was refused under PASTA_CI")
            }
        }
        source.resume()
        terminationSource = source
    }

    /// One line per window, for the CI log when a quit is refused.
    @MainActor
    private static func windowStateDescription() -> String {
        var lines = ["PASTA_CI_WINDOWS modalWindow=\(NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "nil")"]
        for window in NSApp.windows {
            lines.append(
                "  \(type(of: window)) title=\"\(window.title)\" visible=\(window.isVisible) isSheet=\(window.isSheet) attachedSheet=\(window.attachedSheet != nil) level=\(window.level.rawValue)"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
