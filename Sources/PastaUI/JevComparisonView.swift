import PastaCore
import SwiftUI

@MainActor
public final class JevComparisonRunState: ObservableObject {
    @Published public var progress: JevComparisonProgress
    @Published public var isCancelling = false
    public let destination: String
    public var onCancel: (() -> Void)?

    public init(total: Int, destination: String) {
        self.progress = JevComparisonProgress(total: total, completed: 0, agreements: 0, failed: 0)
        self.destination = destination
    }
}

public struct JevComparisonProgressView: View {
    @ObservedObject private var state: JevComparisonRunState

    public init(state: JevComparisonRunState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comparing with Jev")
                .font(.headline)
            Text("Sending supported entries to \(state.destination). Pasta's classifications are not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: state.progress.fraction)
            HStack {
                Text("\(state.progress.completed) of \(state.progress.total) · \(state.progress.remaining) remaining")
                Spacer()
                Text("\(state.progress.agreements) agree · \(state.progress.failed) failed")
                    .foregroundStyle(state.progress.failed > 0 ? Color.orange : Color.secondary)
            }
            .font(.caption.monospacedDigit())
            HStack {
                Spacer()
                Button(state.isCancelling ? "Cancelling…" : "Cancel") {
                    state.isCancelling = true
                    state.onCancel?()
                }
                .disabled(state.isCancelling)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

public struct JevComparisonView: View {
    public enum ExportFormat: Sendable {
        case json
        case csv
    }

    public let report: JevComparisonReport
    public let onExport: ((ExportFormat) -> Void)?
    @State private var filter: Filter = .all
    @State private var pair: JevCategoryPair?

    public init(report: JevComparisonReport, onExport: ((ExportFormat) -> Void)? = nil) {
        self.report = report
        self.onExport = onExport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let banner = statusBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack(alignment: .top) {
                summary("Compared", "\(report.compared)")
                summary("Agreement", report.compared == 0 ? "—" : percent(report.agreementRate))
                summary("Differences", "\(report.disagreements)")
                summary("Failed", "\(report.failed)")
                summary("Skipped", "\(report.skipped)", detail: skipDetail)
                summary("Jev latency", latencyText, detail: report.latencySummary.map { "p95 \(milliseconds($0.p95))" })
            }

            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: filter) { _, newValue in
                    if newValue != .differences { pair = nil }
                }

                Picker("Pair", selection: $pair) {
                    Text("All pairs").tag(JevCategoryPair?.none)
                    ForEach(report.disagreementPairs.prefix(40)) { value in
                        Text("\(value.local.displayTitle) → \(value.jev.displayTitle) (\(value.count))")
                            .tag(Optional(value))
                    }
                }
                .frame(maxWidth: 280)
                .disabled(report.disagreementPairs.isEmpty)
                .onChange(of: pair) { _, newValue in
                    if newValue != nil { filter = .differences }
                }
            }

            HSplitView {
                Table(filteredRows) {
                    TableColumn("Date") { row in
                        Text(row.timestamp, format: .dateTime.year().month().day().hour().minute())
                    }
                    TableColumn("Source") { row in
                        Text(row.sourceApp ?? "Unknown")
                    }
                    TableColumn("Pasta") { row in
                        Text(row.localCategory.displayTitle)
                    }
                    TableColumn("Jev") { row in
                        jevCell(row)
                    }
                    TableColumn("Confidence") { row in
                        Text(row.confidence.map(percent) ?? "—")
                            .monospacedDigit()
                    }
                    TableColumn("Latency") { row in
                        Text(row.latency.map(milliseconds) ?? "—")
                            .monospacedDigit()
                    }
                }
                .frame(minWidth: 560)

                categoryBreakdown
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 540)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pasta vs Jev")
                    .font(.title2.weight(.semibold))
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let onExport {
                Menu("Export") {
                    Button("JSON…") { onExport(.json) }
                    Button("CSV…") { onExport(.csv) }
                }
                .fixedSize()
                .help("Exports classifications and metadata only. Clipboard content and the API key are never included.")
            }
        }
    }

    private var headerDetail: String {
        var parts = ["\(report.total) history entries"]
        if let host = report.endpointHost { parts.append(host) }
        let models = report.jevModels
        parts.append(models.isEmpty ? "model \(report.requestedModel)" : "model \(models.joined(separator: ", "))")
        return parts.joined(separator: " · ")
    }

    private var statusBanner: String? {
        if let abortReason = report.abortReason { return abortReason }
        if report.wasCancelled { return "Comparison cancelled. Entries not yet sent are listed as skipped (Not attempted)." }
        return nil
    }

    private var skipDetail: String? {
        guard let top = report.skipReasons.max(by: { $0.count < $1.count }) else { return nil }
        return report.skipReasons.count == 1 ? top.reason.displayTitle : "Mostly \(top.reason.displayTitle.lowercased())"
    }

    private var latencyText: String {
        report.latencySummary.map { milliseconds($0.median) } ?? "—"
    }

    private var categoryBreakdown: some View {
        List {
            Section("Agreement by Pasta category") {
                ForEach(report.agreementByPastaCategory) { item in
                    HStack {
                        Text(item.category.displayTitle)
                        Spacer()
                        Text("\(percent(item.rate)) of \(item.compared)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !report.skipReasons.isEmpty {
                Section("Skipped") {
                    ForEach(report.skipReasons, id: \.reason) { item in
                        HStack {
                            Text(item.reason.displayTitle)
                            Spacer()
                            Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func jevCell(_ row: JevComparisonRow) -> some View {
        switch row.outcome {
        case .agreement, .disagreement:
            Text(jevTitle(row))
                .foregroundStyle(row.outcome == .agreement ? Color.primary : Color.orange)
        case .failed:
            Text(row.error ?? "Failed")
                .foregroundStyle(.red)
                .help(row.error ?? "")
        case .skipped:
            Text(row.skipReason?.displayTitle ?? "Skipped")
                .foregroundStyle(.secondary)
        }
    }

    private func jevTitle(_ row: JevComparisonRow) -> String {
        guard let category = row.jevCategory else { return row.jevChoice ?? "Unknown" }
        if category == .unknown, let choice = row.jevChoice, choice != ContentType.unknown.rawValue {
            return "Unknown (\(choice))"
        }
        return category.displayTitle
    }

    private var filteredRows: [JevComparisonRow] {
        switch filter {
        case .all:
            return report.rows
        case .agreements:
            return report.rows.filter { $0.outcome == .agreement }
        case .differences:
            return report.rows.filter { row in
                guard row.outcome == .disagreement else { return false }
                guard let pair else { return true }
                return row.localCategory == pair.local && row.jevCategory == pair.jev
            }
        case .failures:
            return report.rows.filter { $0.outcome == .failed }
        case .skipped:
            return report.rows.filter { $0.outcome == .skipped }
        }
    }

    private func summary(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func milliseconds(_ value: TimeInterval) -> String {
        "\(Int((value * 1000).rounded())) ms"
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all, agreements, differences, failures, skipped
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .agreements: return "Agreements"
            case .differences: return "Differences"
            case .failures: return "Failures"
            case .skipped: return "Skipped"
            }
        }
    }
}
