import AppKit
import SwiftUI

/// A user-requested, read-only snapshot. Collection follows the sheet's lifetime.
struct SyncDiagnosticsSheet: View {
    let collectReport: @MainActor () async -> String
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""
    @State private var isLoading = true
    @State private var refreshID = 0
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync Diagnostics")
                .font(.title2.bold())
            Text("Compare this report with your other device. Clipboard contents are excluded; local and iCloud history are unchanged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking iCloud and local history…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("syncDiagnostics.progress")
            }

            ScrollView {
                Text(report)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("syncDiagnostics.report")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Refresh") {
                    isLoading = true
                    refreshID += 1
                }
                .disabled(isLoading)
                .accessibilityIdentifier("syncDiagnostics.refresh")
                Button(didCopy ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    didCopy = NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(isLoading || report.isEmpty)
                .accessibilityIdentifier("syncDiagnostics.copy")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("syncDiagnostics.done")
            }
        }
        .padding(20)
        .frame(width: 600, height: 540)
        .task(id: refreshID) {
            didCopy = false
            let refreshedReport = await collectReport()
            guard !Task.isCancelled else { return }
            report = refreshedReport
            isLoading = false
        }
    }
}
