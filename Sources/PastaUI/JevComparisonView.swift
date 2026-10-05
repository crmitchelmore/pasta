import PastaCore
import SwiftUI

public struct JevComparisonView: View {
    public let report: JevComparisonReport
    @State private var filter: Filter = .all

    public init(report: JevComparisonReport) {
        self.report = report
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                summary("Compared", "\(report.compared)/\(report.total)")
                summary("Agreement", "\(Int(report.agreementRate * 100))%")
                summary("Differences", "\(report.disagreements)")
                summary("Failed", "\(report.failed)")
                summary("Skipped", "\(report.skipped)")
            }

            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)

            Table(filteredRows) {
                TableColumn("Date") { row in
                    Text(row.timestamp, style: .date)
                }
                TableColumn("Source") { row in
                    Text(row.sourceApp ?? "Unknown")
                }
                TableColumn("Pasta") { row in
                    Text(row.localCategory.displayTitle)
                }
                TableColumn("Jev") { row in
                    Text(row.jevCategory?.displayTitle ?? row.error ?? "Unknown")
                        .foregroundStyle(row.error == nil ? Color.primary : Color.red)
                }
                TableColumn("Confidence") { row in
                    Text(row.confidence.map { "\(Int($0 * 100))%" } ?? "—")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 480)
    }

    private var filteredRows: [JevComparisonRow] {
        switch filter {
        case .all: return report.rows
        case .agreements: return report.rows.filter(\.isAgreement)
        case .differences: return report.rows.filter { !$0.isAgreement && $0.error == nil }
        case .failures: return report.rows.filter { $0.error != nil }
        }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all, agreements, differences, failures
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .agreements: return "Agreements"
            case .differences: return "Differences"
            case .failures: return "Failures"
            }
        }
    }
}
