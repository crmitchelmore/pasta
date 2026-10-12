import PastaCore
import SwiftUI

@MainActor
public final class JevComparisonRunState: ObservableObject {
    @Published public var progress: JevComparisonProgress
    @Published public var isCancelling = false
    public let destination: String
    @Published public var title: String
    @Published public var detail: String
    public var onCancel: (() -> Void)?

    public init(total: Int, destination: String, title: String = "Comparing with Jev", changesHistory: Bool = false) {
        self.progress = JevComparisonProgress(total: total, completed: 0, agreements: 0, failed: 0)
        self.destination = destination
        self.title = title
        self.detail = changesHistory ? "Sending supported entries to \(destination). Completed, known decisions update unchanged saved entries."
            : "Sending supported entries to \(destination). Saved classifications are not changed."
    }
}

public struct JevComparisonProgressView: View {
    @ObservedObject private var state: JevComparisonRunState

    public init(state: JevComparisonRunState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.title)
                .font(.headline)
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.progress.total == 0 {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: state.progress.fraction)
            }
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
        .frame(width: 480)
    }
}

public struct JevComparisonView: View {
    public enum ExportFormat: Sendable {
        case json
        case csv
    }

    public let report: JevComparisonReport
    public let onExport: ((ExportFormat) -> Void)?
    private let originalEntries: [UUID: ClipboardEntry]
    private let rowsByID: [UUID: JevComparisonRow]
    private let additionalReport: JevComparisonReport?
    private let additionalRows: [UUID: JevComparisonRow]
    private let onCopy: ((ClipboardEntry) -> Void)?
    @State private var filter: Filter = .all
    @State private var pair: JevCategoryPair?
    @State private var selectedRowID: UUID?

    public init(
        report: JevComparisonReport,
        originalEntries: [UUID: ClipboardEntry] = [:],
        onCopy: ((ClipboardEntry) -> Void)? = nil,
        onExport: ((ExportFormat) -> Void)? = nil
    ) {
        self.report = report
        self.originalEntries = originalEntries
        self.rowsByID = report.rows.reduce(into: [:]) { $0[$1.id] = $1 }
        self.additionalReport = report.additionalReports?.first
        self.additionalRows = (report.additionalReports?.first?.rows ?? []).reduce(into: [:]) { $0[$1.id] = $1 }
        self.onCopy = onCopy
        self.onExport = onExport
        _selectedRowID = State(initialValue: report.rows.first?.id)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let applicationSummary = report.applicationSummary {
                Label(applicationSummary, systemImage: "tray.full")
                    .font(.callout).textSelection(.enabled)
            }

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
                summary("\(report.providerTitle) latency", latencyText, detail: report.latencySummary.map { "p95 \(milliseconds($0.p95))" })
            }
            if let additionalReport {
                HStack(spacing: 16) {
                    Text(additionalReport.providerTitle).fontWeight(.semibold)
                    Text("\(additionalReport.compared) compared · \(percent(additionalReport.agreementRate)) agreement · \(additionalReport.failed) failed · \(additionalReport.skipped) skipped")
                    if let latency = additionalReport.latencySummary {
                        Text("Median \(milliseconds(latency.median)) · p95 \(milliseconds(latency.p95))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: filter) { _, newValue in
                    selectedRowID = nil
                    if newValue != .differences { pair = nil }
                }

                Picker("\(report.providerTitle) pair", selection: $pair) {
                    Text("All pairs").tag(JevCategoryPair?.none)
                    ForEach(report.disagreementPairs.prefix(40)) { value in
                        Text("\(value.local.displayTitle) → \(value.jev.displayTitle) (\(value.count))")
                            .tag(Optional(value))
                    }
                }
                .frame(maxWidth: 280)
                .disabled(report.disagreementPairs.isEmpty)
                .onChange(of: pair) { _, newValue in
                    selectedRowID = nil
                    if newValue != nil { filter = .differences }
                }
            }

            HSplitView {
                VSplitView {
                    comparisonTable
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if ids.count == 1, let id = ids.first,
                           let entry = originalEntry(for: id), let onCopy {
                            Button("Copy Original Item") { onCopy(entry) }
                        }
                    }
                    .frame(minHeight: 160)

                    itemDetail
                        .frame(minHeight: 200, idealHeight: 280)
                }
                .frame(minWidth: 560)

                categoryBreakdown
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 640)
    }

    @ViewBuilder
    private var comparisonTable: some View {
        if let additionalReport {
            Table(filteredRows, selection: $selectedRowID) {
                TableColumn("Date") { row in
                    Text(row.timestamp, format: .dateTime.year().month().day().hour().minute())
                }
                TableColumn("Source") { row in Text(row.sourceApp ?? "Unknown") }
                TableColumn("Local detectors") { row in Text(row.localCategory.displayTitle) }
                TableColumn(report.providerTitle) { row in jevCell(row) }
                TableColumn("Confidence") { row in
                    Text(row.confidence.map(percent) ?? "—").monospacedDigit()
                }
                TableColumn("Latency") { row in
                    Text(row.latency.map(milliseconds) ?? "—").monospacedDigit()
                }
                TableColumn(additionalReport.providerTitle) { row in
                    if let extra = additionalRows[row.id] {
                        VStack(alignment: .leading, spacing: 2) {
                            jevCell(extra)
                            Text("\(extra.confidence.map(percent) ?? "—") · \(extra.latency.map(milliseconds) ?? "—")")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else {
                        Text("Not attempted").foregroundStyle(.secondary)
                    }
                }
                .width(min: 170, ideal: 190)
            }
        } else {
            Table(filteredRows, selection: $selectedRowID) {
                TableColumn("Date") { row in
                    Text(row.timestamp, format: .dateTime.year().month().day().hour().minute())
                }
                TableColumn("Source") { row in Text(row.sourceApp ?? "Unknown") }
                TableColumn("Local detectors") { row in Text(row.localCategory.displayTitle) }
                TableColumn(report.providerTitle) { row in jevCell(row) }
                TableColumn("Confidence") { row in
                    Text(row.confidence.map(percent) ?? "—").monospacedDigit()
                }
                TableColumn("Latency") { row in
                    Text(row.latency.map(milliseconds) ?? "—").monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var itemDetail: some View {
        if let selectedRowID, let row = rowsByID[selectedRowID] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Original item").font(.headline)
                    Spacer()
                    Text("Local preview · not included in exports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Text("Local detectors: \(row.localCategory.displayTitle)")
                    HStack(spacing: 4) {
                        Text("\(report.providerTitle):")
                        jevCell(row)
                    }
                    if let extra = additionalRows[row.id], let additionalReport {
                        HStack(spacing: 4) {
                            Text("\(additionalReport.providerTitle):")
                            jevCell(extra)
                            Text("\(extra.confidence.map(percent) ?? "—") · \(extra.latency.map(milliseconds) ?? "—")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .textSelection(.enabled)

                if let entry = originalEntry(for: selectedRowID) {
                    if entry.content.prefix(JevSystemOneRequest.maxContentCharacters + 1).count > JevSystemOneRequest.maxContentCharacters,
                       row.jevCategory != nil {
                        Text("Remote models classified only the first \(JevSystemOneRequest.maxContentCharacters.formatted()) characters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    PreviewPanelView(entry: entry, onCopy: onCopy)
                        .id(entry.id)
                } else {
                    ContentUnavailableView(
                        "Original item unavailable",
                        systemImage: "doc",
                        description: Text("This report has no local history snapshot for the selected item.")
                    )
                }
            }
            .padding(.top, 10)
        } else {
            ContentUnavailableView(
                "Select a comparison",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Select a row to inspect the original clipboard item and judge the classifications.")
            )
        }
    }

    func originalEntry(for rowID: UUID?) -> ClipboardEntry? {
        guard let rowID, rowsByID[rowID] != nil else { return nil }
        return originalEntries[rowID]
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Local vs \(report.providerTitle)\(additionalReport.map { " vs \($0.providerTitle)" } ?? "")")
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
        if let additionalReport {
            let additionalModels = additionalReport.jevModels
            parts.append(additionalModels.isEmpty ? additionalReport.requestedModel : additionalModels.joined(separator: ", "))
            if let host = additionalReport.endpointHost { parts.append(host) }
        }
        return parts.joined(separator: " · ")
    }

    private var statusBanner: String? {
        let reports = [report] + (report.additionalReports ?? [])
        let failures = reports.compactMap { item in item.abortReason.map { "\(item.providerTitle): \($0)" } }
        if !failures.isEmpty { return failures.joined(separator: "\n") }
        if reports.contains(where: \.wasCancelled) { return "Comparison cancelled. Entries not yet sent are listed as skipped (Not attempted)." }
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
            Section("\(report.providerTitle) agreement by local category") {
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
            return report.rows.filter { $0.outcome == .agreement && (additionalReport == nil || additionalRows[$0.id]?.outcome == .agreement) }
        case .differences:
            return report.rows.filter { row in
                guard let pair else { return row.outcome == .disagreement || additionalRows[row.id]?.outcome == .disagreement }
                guard row.outcome == .disagreement else { return false }
                return row.localCategory == pair.local && row.jevCategory == pair.jev
            }
        case .failures:
            return report.rows.filter { $0.outcome == .failed || additionalRows[$0.id]?.outcome == .failed }
        case .skipped:
            return report.rows.filter { $0.outcome == .skipped || additionalRows[$0.id]?.outcome == .skipped }
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
