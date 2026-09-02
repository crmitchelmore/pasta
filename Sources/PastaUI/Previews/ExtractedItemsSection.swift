import AppKit
import PastaCore
import PastaDetectors
import SwiftUI

struct ExtractedItemsSection: View {
    private static let batchSize = 100

    let entry: ClipboardEntry

    @State private var items: [PreviewPanelView.ExtractedItem] = []
    @State private var hasMore: Bool = false
    @State private var isLoading: Bool = false
    @State private var loadTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if isLoading || !items.isEmpty {
                SectionBox(title: "Detected Items") {
                    if isLoading && items.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            CopyableValueRow(
                                type: item.type,
                                value: item.value,
                                displayValue: item.displayValue,
                                style: .compact
                            )
                        }
                    }

                    if hasMore {
                        HStack(spacing: 8) {
                            Text("Showing the first \(items.count) detected items.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("Show \(Self.batchSize) more") {
                                loadItems(limit: items.count + Self.batchSize)
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(isLoading)
                        }
                    }
                }
            }
        }
        .onAppear {
            loadItems(limit: Self.batchSize)
        }
        .onChange(of: entry.id) { _, _ in
            loadItems(limit: Self.batchSize)
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadItems(limit: Int) {
        loadTask?.cancel()
        items = []
        hasMore = false

        guard entry.metadata != nil else {
            isLoading = false
            return
        }

        isLoading = true
        let snapshot = entry

        loadTask = Task {
            let result = await Task.detached(priority: .utility) { () -> ([ExtractedItemPayload], Bool) in
                let extracted = MetadataParser.extractAllValues(
                    from: snapshot.metadata,
                    limit: limit + 1
                )
                let limited = extracted.prefix(limit).map {
                    ExtractedItemPayload(type: $0.type, value: $0.value, displayValue: $0.displayValue)
                }
                return (Array(limited), extracted.count > limit)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                items = result.0.map {
                    PreviewPanelView.ExtractedItem(type: $0.type, value: $0.value, displayValue: $0.displayValue)
                }
                hasMore = result.1
                isLoading = false
            }
        }
    }

    private struct ExtractedItemPayload: Sendable {
        let type: ContentType
        let value: String
        let displayValue: String
    }
}
