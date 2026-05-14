import AppKit
import SwiftUI

import PastaCore
import PastaDetectors
import PastaUI

extension PanelContentView {
    enum Preload {
        static let limit = 200
    }

    func schedulePreload(for entries: [ClipboardEntry]) {
        preloadTask?.cancel()
        let snapshot = entries

        preloadTask = Task {
            let result = await Task.detached(priority: .utility) { () -> (entriesByType: [ContentType?: [ClipboardEntry]], effectiveTypeCounts: [ContentType: Int], sourceAppCounts: [String: Int], domainCounts: [String: Int]) in
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
                let urlDetector = URLDetector()

                for entry in snapshot {
                    counts[entry.contentType, default: 0] += 1
                    let app = entry.sourceApp ?? "Unknown"
                    sourceAppCounts[app, default: 0] += 1
                    if entry.contentType == .url {
                        let domains = Set(urlDetector.detect(in: entry.content).map(\.domain))
                        for domain in domains {
                            domainCounts[domain, default: 0] += 1
                        }
                    }
                }

                let imageFilePathCount = snapshot.reduce(0) { acc, entry in
                    guard entry.contentType == .filePath else { return acc }
                    return acc + (filePathIsImage(entry.metadata) ? 1 : 0)
                }

                if imageFilePathCount > 0 {
                    counts[.image, default: 0] += imageFilePathCount
                }

                for type in MetadataParser.extractableTypes {
                    var containsCount = 0
                    for entry in snapshot {
                        guard entry.contentType != type else { continue }
                        if MetadataParser.containsType(type, in: entry.metadata) {
                            containsCount += 1
                        }
                    }

                    if containsCount > 0 {
                        counts[type, default: 0] += containsCount
                    }
                }

                for type in ContentType.allCases {
                    var matches: [ClipboardEntry] = []
                    matches.reserveCapacity(Preload.limit)

                    if MetadataParser.extractableTypes.contains(type) {
                        for entry in snapshot {
                            if entry.containsType(type) {
                                matches.append(entry)
                                if matches.count >= Preload.limit { break }
                            }
                        }
                    } else {
                        for entry in snapshot {
                            if entry.contentType == type {
                                matches.append(entry)
                                if matches.count >= Preload.limit { break }
                            }
                        }
                    }

                    out[type] = matches
                }

                return (out, counts, sourceAppCounts, domainCounts)
            }.value

            await MainActor.run {
                preloadedEntriesByType = result.entriesByType
                preloadedEffectiveTypeCounts = result.effectiveTypeCounts
                preloadedSourceAppCounts = result.sourceAppCounts
                preloadedDomainCounts = result.domainCounts

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
                entry.sourceApp?.localizedCaseInsensitiveContains(sourceFilter) == true
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

        searchTask = Task(priority: .userInitiated) {
            let result: [ClipboardEntry]
            do {
                let matches = try service.search(
                    query: query,
                    contentType: searchContentType,
                    limit: Preload.limit,
                    pinnedOnly: pinnedOnly
                )
                guard !Task.isCancelled else { return }
                result = Self.filterEntries(
                    matches.map { $0.entry },
                    contentTypeFilter: typeFilter,
                    sourceFilter: sourceFilter,
                    urlDomainFilter: domainFilter,
                    pinnedOnly: pinnedOnly,
                    limit: limit
                )
            } catch {
                result = []
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                displayedEntries = result
            }
        }
    }
}
