import PastaCore
import PastaDetectors
import SwiftUI

public struct FilterSidebarView: View {
    public let entries: [ClipboardEntry]

    private let effectiveTypeCountsOverride: [ContentType: Int]?
    private let sourceAppCountsOverride: [String: Int]?

    @Binding private var selectedContentType: ContentType?
    @Binding private var selectedURLDomain: String?
    @Binding private var selection: FilterSelection?

    @State private var showDomains: Bool = false
    @State private var showSourceApps: Bool = true
    @State private var showAllTypes: Bool = false
    @State private var showAllApps: Bool = false

    public init(
        entries: [ClipboardEntry],
        effectiveTypeCounts: [ContentType: Int]? = nil,
        sourceAppCounts: [String: Int]? = nil,
        selectedContentType: Binding<ContentType?>,
        selectedURLDomain: Binding<String?>,
        selection: Binding<FilterSelection?>
    ) {
        self.entries = entries
        effectiveTypeCountsOverride = effectiveTypeCounts
        sourceAppCountsOverride = sourceAppCounts
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

            Section {
                let visibleTypes = showAllTypes ? sortedContentTypes : sortedContentTypes.filter { $0.count > 0 }
                ForEach(visibleTypes, id: \.type) { item in
                    sidebarRow(
                        title: typeTitle(item.type),
                        systemImageName: item.type.systemImageName,
                        count: item.count,
                        tint: item.type.tint,
                        selectionValue: .type(item.type)
                    )
                }
                
                if !showAllTypes && hasHiddenTypes {
                    Button {
                        withAnimation { showAllTypes = true }
                    } label: {
                        Label("Show All Types", systemImage: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("Types")
                    Spacer()
                    if showAllTypes {
                        Button("Hide Empty") {
                            withAnimation { showAllTypes = false }
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            
            if !sourceAppCounts.isEmpty {
                Section {
                    DisclosureGroup("Source Apps", isExpanded: $showSourceApps) {
                        let visibleApps = showAllApps ? sortedSourceApps : sortedSourceApps.filter { $0.count > 0 }
                        ForEach(visibleApps, id: \.app) { item in
                            sidebarRow(
                                title: item.displayName,
                                systemImageName: "app",
                                count: item.count,
                                selectionValue: .sourceApp(item.app)
                            )
                        }
                        
                        if !showAllApps && hasHiddenApps {
                            Button {
                                withAnimation { showAllApps = true }
                            } label: {
                                Label("Show All Apps", systemImage: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            let hasAnyURLs = entries.contains { $0.contentType == .url }
            if hasAnyURLs {
                Section {
                    DisclosureGroup("Domains", isExpanded: $showDomains) {
                        if showDomains {
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
    
    /// Returns type counts including entries that contain a type in metadata (not just primary type)
    private var effectiveTypeCounts: [ContentType: Int] {
        if let effectiveTypeCountsOverride {
            return effectiveTypeCountsOverride
        }

        var counts = typeCounts
        
        // Count file paths that are images and add to image count
        let imageFilePathCount = entries.filter { entry in
            guard entry.contentType == .filePath else { return false }
            return filePathIsImage(entry)
        }.count
        
        if imageFilePathCount > 0 {
            counts[.image, default: 0] += imageFilePathCount
        }
        
        // For extractable types, also count entries that CONTAIN items of that type in metadata
        // but don't have that as their primary type
        for type in MetadataParser.extractableTypes {
            let containsCount = entries.filter { entry in
                // Don't double-count entries that already have this as primary type
                guard entry.contentType != type else { return false }
                return MetadataParser.containsType(type, in: entry.metadata)
            }.count
            
            if containsCount > 0 {
                counts[type, default: 0] += containsCount
            }
        }
        
        return counts
    }
    
    private var sortedContentTypes: [(type: ContentType, count: Int)] {
        ContentType.allCases.map { type in
            (type, effectiveTypeCounts[type, default: 0])
        }.sorted { a, b in
            if a.count == b.count { return a.type.displayTitle < b.type.displayTitle }
            return a.count > b.count
        }
    }
    
    private var hasHiddenTypes: Bool {
        sortedContentTypes.contains { $0.count == 0 }
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
    
    // MARK: - Source App Counts
    
    private var sourceAppCounts: [String: Int] {
        if let sourceAppCountsOverride {
            return sourceAppCountsOverride
        }

        var counts: [String: Int] = [:]
        for entry in entries {
            let app = entry.sourceApp ?? "Unknown"
            counts[app, default: 0] += 1
        }
        return counts
    }
    
    private var sortedSourceApps: [(app: String, displayName: String, count: Int)] {
        sourceAppCounts
            .sorted { a, b in
                if a.value == b.value { return a.key < b.key }
                return a.value > b.value
            }
            .map { (app: $0.key, displayName: appDisplayName($0.key), count: $0.value) }
    }
    
    private var hasHiddenApps: Bool {
        sortedSourceApps.contains { $0.count == 0 }
    }
    
    private func appDisplayName(_ bundleId: String) -> String {
        if bundleId == "Unknown" || bundleId.isEmpty {
            return "Unknown"
        }
        if bundleId == "Continuity" {
            return "📱 Continuity"
        }
        // Extract app name from bundle identifier
        let parts = bundleId.split(separator: ".")
        if let last = parts.last {
            return String(last).capitalized
        }
        return bundleId
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
        case .sourceApp:
            // Source app filter is handled separately via FilterSelection
            selectedContentType = nil
            selectedURLDomain = nil
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
