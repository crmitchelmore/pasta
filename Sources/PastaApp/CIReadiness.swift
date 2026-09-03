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
/// history load has come back from the database AND clipboard monitoring is
/// running; CI waits for that, then sends SIGTERM and asserts exit code 0.
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

            // AppKit silently refuses `terminate:` while a sheet or modal session
            // is up — on a fresh runner that is the first-launch onboarding
            // sheet. Dismiss them so the harness exercises the real quit path
            // (applicationShouldTerminate → exit 0) instead of timing out.
            dismissSheetsAndModals()

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

    /// Stops any modal session and closes every window that has a sheet
    /// attached. Merely ending the sheet is not enough: SwiftUI re-presents
    /// the onboarding sheet while its `isPresented` binding is still true, so
    /// the parent window goes too (CI is quitting anyway).
    @MainActor
    private static func dismissSheetsAndModals() {
        if NSApp.modalWindow != nil {
            NSApp.stopModal()
        }
        for window in NSApp.windows {
            guard let sheet = window.attachedSheet else { continue }
            window.endSheet(sheet)
            window.close()
        }
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
