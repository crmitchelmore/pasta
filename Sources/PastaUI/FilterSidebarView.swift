import PastaCore
import SwiftUI

public struct FilterSidebarView: View {
    public let entries: [ClipboardEntry]

    private let effectiveTypeCountsOverride: [ContentType: Int]?
    private let sourceAppCountsOverride: [String: Int]?
    private let domainCountsOverride: [String: Int]?

    @Binding private var selectedContentType: ContentType?
    @Binding private var selectedURLDomain: String?
    @Binding private var selection: FilterSelection?

    @State private var showDomains: Bool = false
    @State private var showSourceApps: Bool = true
    @State private var showAllTypes: Bool = false
    @State private var showAllApps: Bool = false
    @State private var fallbackTypeCounts: [ContentType: Int] = [:]
    @State private var fallbackSourceAppCounts: [String: Int] = [:]
    @State private var fallbackCountsTask: Task<Void, Never>? = nil

    public init(
        entries: [ClipboardEntry],
        effectiveTypeCounts: [ContentType: Int]? = nil,
        sourceAppCounts: [String: Int]? = nil,
        domainCounts: [String: Int]? = nil,
        selectedContentType: Binding<ContentType?>,
        selectedURLDomain: Binding<String?>,
        selection: Binding<FilterSelection?>
    ) {
        self.entries = entries
        effectiveTypeCountsOverride = effectiveTypeCounts
        sourceAppCountsOverride = sourceAppCounts
        domainCountsOverride = domainCounts
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

            let hasAnyURLs = domainCountsOverride.map { !$0.isEmpty } ?? (effectiveTypeCounts[.url, default: 0] > 0)
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
        .onAppear {
            syncSelectionFromBindings()
            scheduleFallbackCountsRebuild()
        }
        .onDisappear {
            fallbackCountsTask?.cancel()
            fallbackCountsTask = nil
        }
        .onChange(of: entriesChangeToken) { _, _ in
            scheduleFallbackCountsRebuild()
        }
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

    private var entriesChangeToken: Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        if let first = entries.first?.id {
            hasher.combine(first)
        }
        if let last = entries.last?.id {
            hasher.combine(last)
        }
        return hasher.finalize()
    }
    
    /// Returns precomputed type counts (off-main) to keep sidebar interactions responsive.
    private var effectiveTypeCounts: [ContentType: Int] {
        if let effectiveTypeCountsOverride {
            return effectiveTypeCountsOverride
        }
        return fallbackTypeCounts
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
    
    // MARK: - Source App Counts

    private var sourceAppCounts: [String: Int] {
        if let sourceAppCountsOverride {
            return sourceAppCountsOverride
        }
        return fallbackSourceAppCounts
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
        if let domainCountsOverride {
            return domainCountsOverride
        }
        // Domain extraction is intentionally done off-main by callers and supplied via overrides.
        return [:]
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

    private func scheduleFallbackCountsRebuild() {
        fallbackCountsTask?.cancel()
        let snapshot = entries

        fallbackCountsTask = Task {
            let result = await Task.detached(priority: .utility) { () -> ([ContentType: Int], [String: Int]) in
                var typeCounts: [ContentType: Int] = [:]
                var appCounts: [String: Int] = [:]

                for entry in snapshot {
                    typeCounts[entry.contentType, default: 0] += 1
                    let app = entry.sourceApp ?? "Unknown"
                    appCounts[app, default: 0] += 1
                }

                return (typeCounts, appCounts)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                fallbackTypeCounts = result.0
                fallbackSourceAppCounts = result.1
            }
        }
    }
}
