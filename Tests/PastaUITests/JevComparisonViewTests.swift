import AppKit
import PastaCore
import SwiftUI
import XCTest
@testable import PastaUI

final class JevComparisonViewTests: XCTestCase {
    @MainActor
    func testDecisionSettingsAndComparisonRenderWithoutLeakingLocalSnapshots() throws {
        for provider in RemoteClassificationProvider.allCases {
            try render(Form { DecisionModelsSettingsContent(isOnboarding: true, provider: provider, readAPIKey: { nil }) }
                .formStyle(.grouped), size: CGSize(width: 540, height: 330), name: "\(provider.rawValue)-setup")
        }
        try render(DetectionRulesSettingsTab(readAPIKey: { nil }), size: CGSize(width: 900, height: 760), name: "decision-settings")
        try render(Form { DecisionClassifierSettingsSection() }.formStyle(.grouped),
                   size: CGSize(width: 900, height: 450), name: "shared-rules")

        let custom = ClipboardEntry(content: "CUST-123", contentType: .text,
                                    metadata: #"{"decisionClassification":{"label":"Customer ID","provider":"jev"}}"#)
        try render(PreviewPanelView(entry: custom), size: CGSize(width: 420, height: 540), name: "custom-preview")
        let customRow = JevComparisonRow(id: custom.id, timestamp: custom.timestamp, sourceApp: nil,
                                         localCategory: .text, jevCategory: .text, decisionLabel: "Customer ID")
        try render(JevComparisonView(report: JevComparisonReport(generatedAt: Date(), total: 1, rows: [customRow]),
                                     originalEntries: [custom.id: custom]),
                   size: CGSize(width: 1000, height: 760), name: "custom-comparison")

        let content = "LOCAL_ONLY_SENTINEL_8DA2"
        let original = ClipboardEntry(content: content, contentType: .text)
        let unrelated = ClipboardEntry(content: "Not in this report", contentType: .text)
        let microsoftRow = JevComparisonRow(id: original.id, timestamp: original.timestamp, sourceApp: nil,
                                            localCategory: .text, jevCategory: .code, confidence: 0.91,
                                            latency: 0.08, jevModel: "Microsoft-Decision-1")
        let extras = [
            JevComparisonReport(generatedAt: Date(), requestedModel: "microsoft-decision-1",
                                total: 1, rows: [microsoftRow], provider: .microsoftDecision),
            JevComparisonReport(generatedAt: Date(), requestedModel: RemoteClassificationProvider.openAI.defaultModel,
                                total: 1, rows: [comparisonRow(for: original)], provider: .openAI)
        ]
        let report = JevComparisonReport(generatedAt: Date(), total: 1, rows: [comparisonRow(for: original)]).including(extras)
        for provider in [RemoteClassificationProvider.microsoftDecision, .openAI] {
            let view = JevComparisonView(report: report, additionalProvider: provider)
            XCTAssertEqual(view.additionalReport?.provider, provider)
            XCTAssertEqual(view.report.additionalReports?.count, 2, "selecting \(provider) must not discard other reports")
        }

        var changed = original
        changed.content = "Changed after comparison"
        changed.contentType = .code
        let comparison = JevComparisonView(report: report, originalEntries: [original.id: original],
                                           additionalProvider: .openAI, onCopy: { _ in })
        try render(comparison, size: CGSize(width: 1220, height: 760), name: "comparison", env: "JEV_PREVIEW_SNAPSHOT")
        // The detail pane shows the snapshot taken at comparison time, never later edits.
        XCTAssertEqual(comparison.originalEntry(for: original.id)?.content, content)
        XCTAssertEqual(comparison.originalEntry(for: original.id)?.contentType, .text)
        XCTAssertNotEqual(comparison.originalEntry(for: original.id)?.content, changed.content)
        XCTAssertEqual(comparison.report.rows.first?.jevCategory, .prose)
        let unrelatedOnly = JevComparisonView(report: report, originalEntries: [unrelated.id: unrelated])
        XCTAssertNil(unrelatedOnly.originalEntry(for: nil))
        XCTAssertNil(unrelatedOnly.originalEntry(for: original.id))
        XCTAssertNil(unrelatedOnly.originalEntry(for: unrelated.id))
        // Local preview content must never enter shareable report exports.
        XCTAssertFalse(String(decoding: try comparison.report.jsonData(), as: UTF8.self).contains(content))
        XCTAssertFalse(comparison.report.csv().contains(content))
    }

    private func comparisonRow(for entry: ClipboardEntry) -> JevComparisonRow {
        JevComparisonRow(id: entry.id, timestamp: entry.timestamp, sourceApp: entry.sourceApp,
                         localCategory: entry.contentType, jevCategory: .prose)
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize, name: String, env: String? = nil) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), name)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertEqual(hosting.bounds.size, size, name)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width * window.backingScaleFactor), name)
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * window.backingScaleFactor), name)
        let environment = ProcessInfo.processInfo.environment
        if let path = env.flatMap({ environment[$0] }) {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        } else if env == nil, let directory = environment["DECISION_UI_SNAPSHOT_DIR"] {
            let destination = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        }
    }
}
