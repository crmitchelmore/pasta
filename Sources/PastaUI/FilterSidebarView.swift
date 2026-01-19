import PastaCore
import PastaDetectors
import SwiftUI

public struct FilterSidebarView: View {
    public let entries: [ClipboardEntry]

    @Binding private var selectedContentType: ContentType?
    @Binding private var selectedURLDomain: String?

    public init(
        entries: [ClipboardEntry],
        selectedContentType: Binding<ContentType?>,
        selectedURLDomain: Binding<String?>
    ) {
        self.entries = entries
        _selectedContentType = selectedContentType
        _selectedURLDomain = selectedURLDomain
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter")
                .font(.headline)

            filterButton(
                title: "All",
                systemImageName: "line.3.horizontal.decrease.circle",
                count: entries.count,
                isSelected: selectedContentType == nil,
                action: {
                    selectedContentType = nil
                    selectedURLDomain = nil
                }
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ContentType.allCases, id: \.self) { type in
                        filterButton(
                            title: typeTitle(type),
                            systemImageName: type.systemImageName,
                            count: typeCounts[type, default: 0],
                            isSelected: selectedContentType == type,
                            tint: type.tint,
                            action: {
                                selectedContentType = type
                                if type != .url {
                                    selectedURLDomain = nil
                                }
                            }
                        )
                    }

                    if selectedContentType == .url, !domainCounts.isEmpty {
                        Divider().padding(.vertical, 6)

                        Text("Domains")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        filterButton(
                            title: "All Domains",
                            systemImageName: "globe",
                            count: domainCounts.values.reduce(0, +),
                            isSelected: selectedURLDomain == nil,
                            action: { selectedURLDomain = nil }
                        )

                        ForEach(sortedDomains, id: \.domain) { item in
                            filterButton(
                                title: item.domain,
                                systemImageName: "link",
                                count: item.count,
                                isSelected: selectedURLDomain == item.domain,
                                action: { selectedURLDomain = item.domain }
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var typeCounts: [ContentType: Int] {
        var counts: [ContentType: Int] = [:]
        for entry in entries {
            counts[entry.contentType, default: 0] += 1
        }
        return counts
    }

    private var domainCounts: [String: Int] {
        let detector = URLDetector()
        var counts: [String: Int] = [:]

        for entry in entries where entry.contentType == .url {
            let domains = Set(detector.detect(in: entry.content).map(\.domain))
            for d in domains {
                counts[d, default: 0] += 1
            }
        }

        return counts
    }

    private var sortedDomains: [(domain: String, count: Int)] {
        domainCounts
            .sorted { a, b in
                if a.value == b.value { return a.key < b.key }
                return a.value > b.value
            }
            .map { ($0.key, $0.value) }
    }

    private func filterButton(
        title: String,
        systemImageName: String,
        count: Int,
        isSelected: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImageName)
                    .frame(width: 16)
                    .foregroundStyle(tint ?? .secondary)

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1.0)
        .help(title)
    }

    private func typeTitle(_ type: ContentType) -> String {
        switch type {
        case .envVar: return "Env"
        case .envVarBlock: return "Env Block"
        default:
            return type.rawValue.capitalized
        }
    }
}
