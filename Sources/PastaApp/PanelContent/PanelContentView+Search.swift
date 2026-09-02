import AppKit
import SwiftUI

import PastaCore
import PastaDetectors
import PastaUI

extension PanelContentView {
    enum Preload {
        /// Kept in lock-step with the search bar's "200+" badge cap.
        static let limit = SearchBarView.resultCountCap
        /// Coalesce bursts of copies so a rapid series of clipboard changes
        /// triggers one full rescan instead of one per emission.
        static let debounceNanoseconds: UInt64 = 250_000_000
    }

    struct PreloadResult: Sendable {
        var entriesByType: [ContentType?: [ClipboardEntry]]
        var effectiveTypeCounts: [ContentType: Int]
        var sourceAppCounts: [String: Int]
        var domainCounts: [String: Int]
        var pinnedCount: Int
    }

    func schedulePreload(for entries: [ClipboardEntry]) {
        preloadTask?.cancel()
        let snapshot = entries

        preloadTask = Task {
            try? await Task.sleep(nanoseconds: Preload.debounceNanoseconds)
            guard !Task.isCancelled else { return }

            let result = await withCancellableDetachedTask(priority: .utility) { () -> PreloadResult? in
                func filePathIsImage(_ metadata: String?) -> Bool {
                    guard let meta = metadata,
                          let data = meta.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                          let paths = dict["filePaths"] as? [[String: Any]],
                          let first = paths.first,
                          let fileType = first["fileType"] as? String
                    else { return false }

                    return fileType == "image"
                }

                var out: [ContentType?: [ClipboardEntry]] = [:]
                out[nil] = Array(snapshot.prefix(Preload.limit))

                var counts: [ContentType: Int] = [:]
                var sourceAppCounts: [String: Int] = [:]
                var domainCounts: [String: Int] = [:]
                var pinnedCount = 0
                let urlDetector = URLDetector()

                let extractableTypes = MetadataParser.extractableTypes
                var buckets: [ContentType: [ClipboardEntry]] = [:]
                for type in ContentType.allCases {
                    buckets[type] = []
                }

                // Single pass builds counts and every per-type bucket at once;
                // the previous per-type passes rescanned the whole history once
                // per content type.
                for entry in snapshot {
                    guard !Task.isCancelled else { return nil }

                    counts[entry.contentType, default: 0] += 1
                    if entry.isPinned { pinnedCount += 1 }
                    let app = entry.sourceApp ?? "Unknown"
                    sourceAppCounts[app, default: 0] += 1
                    if entry.contentType == .url {
                        let domains = Set(urlDetector.detect(in: entry.content).map(\.domain))
                        for domain in domains {
                            domainCounts[domain, default: 0] += 1
                        }
                    }

                    if entry.contentType == .filePath, filePathIsImage(entry.metadata) {
                        counts[.image, default: 0] += 1
                    }

                    if !extractableTypes.contains(entry.contentType),
                       buckets[entry.contentType, default: []].count < Preload.limit {
                        buckets[entry.contentType, default: []].append(entry)
                    }

                    // `contentTypeMask` was derived from the metadata once, at
                    // insert time, so this is 12 bit tests per entry rather
                    // than 12 substring scans (or a JSON parse) of the
                    // metadata string on every clipboard change.
                    let mask = entry.contentTypeMask
                    for type in extractableTypes {
                        let isPrimary = entry.contentType == type
                        let containsType = isPrimary || mask.contains(type)
                        guard containsType else { continue }

                        if !isPrimary {
                            counts[type, default: 0] += 1
                        }
                        if buckets[type, default: []].count < Preload.limit {
                            buckets[type, default: []].append(entry)
                        }
                    }
                }

                guard !Task.isCancelled else { return nil }

                for (type, matches) in buckets {
                    out[type] = matches
                }

                return PreloadResult(
                    entriesByType: out,
                    effectiveTypeCounts: counts,
                    sourceAppCounts: SourceAppDisplay.groupedCounts(sourceAppCounts),
                    domainCounts: domainCounts,
                    pinnedCount: pinnedCount
                )
            }

            guard !Task.isCancelled, let result else { return }

            await MainActor.run {
                preloadedEntriesByType = result.entriesByType
                preloadedEffectiveTypeCounts = result.effectiveTypeCounts
                preloadedSourceAppCounts = result.sourceAppCounts
                preloadedDomainCounts = result.domainCounts
                preloadedPinnedCount = result.pinnedCount

                // Update display from fresh cache if applicable (resolves race with asyncFilterEntries)
                if let cached = preloadedEntriesForCurrentFilters() {
                    filterTask?.cancel()
                    displayedEntries = cached
                }
            }
        }
    }

    func preloadedEntriesForCurrentFilters() -> [ClipboardEntry]? {
        // Only use preload cache for the common case: no query, no domain filter, no source app filter
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard urlDomainFilter == nil else { return nil }
        guard sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard !pinnedOnlyFilter else { return nil }
        return preloadedEntriesByType[contentTypeFilter]
    }

    func triggerSearchUpdate() {
        searchDebounceTask?.cancel()
        filterTask?.cancel()
        searchTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let cached = preloadedEntriesForCurrentFilters() {
                displayedEntries = cached
            } else {
                asyncFilterEntries()
            }
        } else {
            performSearch(query: trimmed)
        }
    }

    nonisolated static func filterEntries(
        _ input: [ClipboardEntry],
        contentTypeFilter: ContentType?,
        sourceFilter: String,
        urlDomainFilter: String?,
        pinnedOnly: Bool,
        limit: Int
    ) -> [ClipboardEntry] {
        var out = input

        if pinnedOnly {
            out = out.filter { $0.isPinned }
        }

        if let contentTypeFilter {
            if MetadataParser.extractableTypes.contains(contentTypeFilter) {
                out = out.filter { $0.containsType(contentTypeFilter) }
            } else {
                out = out.filter { $0.contentType == contentTypeFilter }
            }
        }

        if !sourceFilter.isEmpty {
            out = out.filter { entry in
                SourceAppDisplay.matches(entry.sourceApp, filter: sourceFilter)
            }
        }

        if contentTypeFilter == .url, let urlDomainFilter {
            let detector = URLDetector()
            out = out.filter { entry in
                Set(detector.detect(in: entry.content).map(\.domain)).contains(urlDomainFilter)
            }
        }

        return Array(out.prefix(limit))
    }

    /// Run entry filtering off the main thread to avoid UI hangs on large datasets
    func asyncFilterEntries() {
        filterTask?.cancel()
        let entries = backgroundService.entries
        let typeFilter = contentTypeFilter
        let srcFilter = sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainFilter = urlDomainFilter
        let pinnedOnly = pinnedOnlyFilter
        let limit = Preload.limit

        filterTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [ClipboardEntry] in
                Self.filterEntries(
                    entries,
                    contentTypeFilter: typeFilter,
                    sourceFilter: srcFilter,
                    urlDomainFilter: domainFilter,
                    pinnedOnly: pinnedOnly,
                    limit: limit
                )
            }.value

            guard !Task.isCancelled else { return }
            displayedEntries = result
        }
    }

    func performSearch(query: String) {
        guard let service = searchService else {
            displayedEntries = []
            return
        }

        searchTask?.cancel()
        let typeFilter = contentTypeFilter
        let sourceFilter = sourceAppFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let domainFilter = urlDomainFilter
        let pinnedOnly = pinnedOnlyFilter
        let limit = Preload.limit
        let searchContentType: ContentType?
        if let typeFilter, MetadataParser.extractableTypes.contains(typeFilter) {
            searchContentType = nil
        } else {
            searchContentType = typeFilter
        }

        searchTask = Task {
            // The FTS read plus row hydration and filtering must stay off the
            // main actor; a plain `Task` here would inherit it.
            let result = await withCancellableDetachedTask(priority: .userInitiated) { () -> [ClipboardEntry] in
                do {
                    let matches = try service.search(
                        query: query,
                        contentType: searchContentType,
                        limit: Preload.limit,
                        pinnedOnly: pinnedOnly
                    )
                    guard !Task.isCancelled else { return [] }
                    return Self.filterEntries(
                        matches.map { $0.entry },
                        contentTypeFilter: typeFilter,
                        sourceFilter: sourceFilter,
                        urlDomainFilter: domainFilter,
                        pinnedOnly: pinnedOnly,
                        limit: limit
                    )
                } catch {
                    return []
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                displayedEntries = result
            }
        }
    }
}
