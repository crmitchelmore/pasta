import PastaCore
import PastaDetectors
import SwiftUI

public struct FilterSidebarView: View {
    public let entries: [ClipboardEntry]

    @Binding private var selectedContentType: ContentType?
    @Binding private var selectedURLDomain: String?
    @Binding private var selection: FilterSelection?

    @State private var showDomains: Bool = false

    public init(
        entries: [ClipboardEntry],
        selectedContentType: Binding<ContentType?>,
        selectedURLDomain: Binding<String?>,
        selection: Binding<FilterSelection?>
    ) {
        self.entries = entries
        _selectedContentType = selectedContentType
        _selectedURLDomain = selectedURLDomain
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section("All") {
                sidebarRow(
                    title: "All",
                    systemImageName: "line.3.horizontal.decrease.circle",
                    count: entries.count,
                    selectionValue: .all
                )
            }

            Section("Types") {
                ForEach(ContentType.allCases, id: \.self) { type in
                    sidebarRow(
                        title: typeTitle(type),
                        systemImageName: type.systemImageName,
                        count: effectiveTypeCounts[type, default: 0],
                        tint: type.tint,
                        selectionValue: .type(type)
                    )
                }
            }

            if !domainCounts.isEmpty {
                Section {
                    DisclosureGroup("Domains", isExpanded: $showDomains) {
                        sidebarRow(
                            title: "All Domains",
                            systemImageName: "globe",
                            count: domainCounts.values.reduce(0, +),
                            selectionValue: .domain("")
                        )

                        ForEach(sortedDomains, id: \.domain) { item in
                            sidebarRow(
                                title: item.domain,
                                systemImageName: "link",
                                count: item.count,
                                selectionValue: .domain(item.domain)
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { syncSelectionFromBindings() }
        .onChange(of: selection) { _, newValue in
            applySelection(newValue)
        }
        .onChange(of: selectedContentType) { _, _ in
            syncSelectionFromBindings()
        }
        .onChange(of: selectedURLDomain) { _, _ in
            syncSelectionFromBindings()
        }
    }

    private var typeCounts: [ContentType: Int] {
        var counts: [ContentType: Int] = [:]
        for entry in entries {
            counts[entry.contentType, default: 0] += 1
        }
        return counts
    }
    
    /// Returns type counts with file path images also counted under .image
    private var effectiveTypeCounts: [ContentType: Int] {
        var counts = typeCounts
        
        // Count file paths that are images and add to image count
        let imageFilePathCount = entries.filter { entry in
            guard entry.contentType == .filePath else { return false }
            return filePathIsImage(entry)
        }.count
        
        if imageFilePathCount > 0 {
            counts[.image, default: 0] += imageFilePathCount
        }
        
        return counts
    }
    
    private func filePathIsImage(_ entry: ClipboardEntry) -> Bool {
        guard let meta = entry.metadata,
              let data = meta.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let paths = dict["filePaths"] as? [[String: Any]],
              let first = paths.first,
              let fileType = first["fileType"] as? String
        else { return false }
        
        return fileType == "image"
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

    private func sidebarRow(
        title: String,
        systemImageName: String,
        count: Int,
        tint: Color? = nil,
        selectionValue: FilterSelection
    ) -> some View {
        let isDisabled = count == 0 && selectionValue != .all
        return Label {
            HStack(spacing: 8) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImageName)
                .foregroundStyle(tint ?? .secondary)
        }
        .tag(selectionValue)
        .disabled(isDisabled)
        .help(title)
    }

    private func applySelection(_ selection: FilterSelection?) {
        switch selection {
        case .none, .all:
            selectedContentType = nil
            selectedURLDomain = nil
        case .type(let type):
            selectedContentType = type
            if type != .url {
                selectedURLDomain = nil
            }
        case .domain(let domain):
            selectedContentType = .url
            selectedURLDomain = domain.isEmpty ? nil : domain
        }
    }

    private func syncSelectionFromBindings() {
        if let domain = selectedURLDomain, !domain.isEmpty {
            selection = .domain(domain)
            showDomains = true
            return
        }
        if let type = selectedContentType {
            selection = .type(type)
            return
        }
        selection = .all
    }

    private func typeTitle(_ type: ContentType) -> String {
        type.displayTitle
    }
}
