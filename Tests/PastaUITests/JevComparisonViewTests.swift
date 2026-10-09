import AppKit
import PastaCore
import SwiftUI
import XCTest
@testable import PastaUI

final class JevComparisonViewTests: XCTestCase {
    @MainActor
    func testComparisonViewRendersWithLocalSnapshot() throws {
        let original = ClipboardEntry(content: "Original text for judging this classification.", contentType: .text)
        let report = JevComparisonReport(generatedAt: Date(), total: 1, rows: [comparisonRow(for: original)])
        let view = JevComparisonView(report: report, originalEntries: [original.id: original], onCopy: { _ in })
            .background(Color(nsColor: .windowBackgroundColor))
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        if let path = ProcessInfo.processInfo.environment["JEV_PREVIEW_SNAPSHOT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testDetailUsesOriginalSnapshotForMatchingComparisonRow() throws {
        let original = ClipboardEntry(content: "Original clipboard text", contentType: .text)
        let row = comparisonRow(for: original)
        let report = JevComparisonReport(generatedAt: Date(), total: 1, rows: [row])
        let view = JevComparisonView(report: report, originalEntries: [original.id: original])
        var changed = original
        changed.content = "Changed after comparison"
        changed.contentType = .code

        let preview = try XCTUnwrap(view.originalEntry(for: row.id))
        XCTAssertEqual(preview.content, "Original clipboard text")
        XCTAssertEqual(preview.contentType, .text)
        XCTAssertNotEqual(preview.content, changed.content)
        XCTAssertEqual(view.report.rows.first?.jevCategory, .prose)
    }

    @MainActor
    func testMissingOrUnrelatedSelectionHasNoOriginalItem() {
        let original = ClipboardEntry(content: "Clipboard text", contentType: .text)
        let unrelated = ClipboardEntry(content: "Not in this report", contentType: .text)
        let report = JevComparisonReport(generatedAt: Date(), total: 1, rows: [comparisonRow(for: original)])
        let view = JevComparisonView(report: report, originalEntries: [unrelated.id: unrelated])

        XCTAssertNil(view.originalEntry(for: nil))
        XCTAssertNil(view.originalEntry(for: original.id))
        XCTAssertNil(view.originalEntry(for: unrelated.id))
    }

    @MainActor
    func testLocalPreviewContentNeverEntersReportExports() throws {
        let content = "LOCAL_ONLY_SENTINEL_8DA2"
        let original = ClipboardEntry(content: content, contentType: .text)
        let report = JevComparisonReport(generatedAt: Date(), total: 1, rows: [comparisonRow(for: original)])
        let view = JevComparisonView(report: report, originalEntries: [original.id: original])

        XCTAssertEqual(view.originalEntry(for: original.id)?.content, content)
        XCTAssertFalse(String(decoding: try view.report.jsonData(), as: UTF8.self).contains(content))
        XCTAssertFalse(view.report.csv().contains(content))
    }

    private func comparisonRow(for entry: ClipboardEntry) -> JevComparisonRow {
        JevComparisonRow(
            id: entry.id,
            timestamp: entry.timestamp,
            sourceApp: entry.sourceApp,
            localCategory: entry.contentType,
            jevCategory: .prose
        )
    }
}
