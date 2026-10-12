import AppKit
import PastaCore
import SwiftUI
import XCTest
@testable import PastaUI

final class DecisionModelSetupViewTests: XCTestCase {
    @MainActor
    func testBothProviderSetupFormsRenderAtOnboardingWidth() throws {
        for provider in RemoteClassificationProvider.allCases {
            let view = Form {
                DecisionModelsSettingsContent(isOnboarding: true, provider: provider, readAPIKey: { nil })
            }
            .formStyle(.grouped)
            try render(view, size: CGSize(width: 540, height: 330), name: "\(provider.rawValue)-setup")
        }
    }

    @MainActor
    func testDecisionFirstSettingsAndSharedRulesRenderAtSettingsWidth() throws {
        try render(DetectionRulesSettingsTab(readAPIKey: { nil }), size: CGSize(width: 900, height: 760), name: "decision-settings")
        try render(Form { DecisionClassifierSettingsSection() }.formStyle(.grouped),
                   size: CGSize(width: 900, height: 450), name: "shared-rules")
    }

    @MainActor
    func testCustomDecisionLabelRendersInPreviewAndComparison() throws {
        let entry = ClipboardEntry(content: "CUST-123", contentType: .text,
                                   metadata: #"{"decisionClassification":{"label":"Customer ID","provider":"jev"}}"#)
        try render(PreviewPanelView(entry: entry), size: CGSize(width: 420, height: 540), name: "custom-preview")
        let row = JevComparisonRow(id: entry.id, timestamp: entry.timestamp, sourceApp: nil,
                                  localCategory: .text, jevCategory: .text, decisionLabel: "Customer ID")
        let report = JevComparisonReport(generatedAt: Date(), total: 1, rows: [row])
        try render(JevComparisonView(report: report, originalEntries: [entry.id: entry]),
                   size: CGSize(width: 1000, height: 760), name: "custom-comparison")
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize, name: String) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertEqual(hosting.bounds.size, size)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width * window.backingScaleFactor))
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * window.backingScaleFactor))
        if let directory = ProcessInfo.processInfo.environment["DECISION_UI_SNAPSHOT_DIR"] {
            let destination = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        }
    }
}
