import Combine
import Foundation
import Fuse

/// Singleton manager that keeps quick search data pre-indexed and ready.
/// This ensures instant appearance when the hotkey is pressed.
@MainActor
public final class QuickSearchManager: ObservableObject {
    public static let shared = QuickSearchManager()
    
    // MARK: - Published State
    
    @Published public var query: String = ""
    @Published public var selectedFilter: ContentType? = nil
    @Published public private(set) var results: [ClipboardEntry] = []
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var availableFilters: [FilterInfo] = []
    @Published public private(set) var isReady: Bool = false
    
    public struct FilterInfo: Equatable, Sendable {
        public let type: ContentType
        public let count: Int
    }
    
    // MARK: - Private State
    
    private var allEntries: [ClipboardEntry] = []
    private var entriesSubscription: AnyCancellable?
    private var searchDebounceTask: Task<Void, Never>?
    
    // Pre-built search index for instant fuzzy search
    private var searchIndex: SearchIndex?
    private let fuse = Fuse(tokenize: true)
    
    private init() {}
    
    // MARK: - Public API
    
    /// Call once at app startup to begin indexing
    public func initialize(entriesPublisher: AnyPublisher<[ClipboardEntry], Never>) {
        entriesSubscription = entriesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.updateEntries(entries)
            }
    }
    
    /// Reset state for fresh search (call when showing quick search)
    public func prepareForSearch() {
        query = ""
        selectedFilter = nil
        selectedIndex = 0
        results = Array(allEntries.prefix(9))
    }
    
    /// Move selection up or down
    public func moveSelection(by delta: Int) {
        let maxIndex = min(results.count, 9) - 1
        guard maxIndex >= 0 else { return }
        selectedIndex = max(0, min(maxIndex, selectedIndex + delta))
    }
    
    /// Get the currently selected entry
    public var selectedEntry: ClipboardEntry? {
        guard selectedIndex >= 0 && selectedIndex < results.count else { return nil }
        return results[selectedIndex]
    }
    
    // MARK: - Entry Updates
    
    private func updateEntries(_ entries: [ClipboardEntry]) {
        let oldCount = allEntries.count
        allEntries = entries
        
        // Build index synchronously (fast enough for typical sizes)
        searchIndex = SearchIndex(entries: entries)
        isReady = true
        PastaLogger.search.debug("Search index rebuilt: \(entries.count) entries")
        
        // Update filters
        computeAvailableFilters()
        
        // If showing results, refresh them
        if query.isEmpty {
            updateResultsImmediate()
        } else if oldCount != entries.count {
            // Content changed, re-search
            performSearch()
        }
    }
    
    private func computeAvailableFilters() {
        var counts: [ContentType: Int] = [:]
        for entry in allEntries.prefix(1000) {
            counts[entry.contentType, default: 0] += 1
        }
        
        availableFilters = counts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { FilterInfo(type: $0.key, count: $0.value) }
    }
    
    // MARK: - Search
    
    /// Called when query or filter changes - debounced search with immediate text display
    public func searchQueryChanged() {
        searchDebounceTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Empty query = immediate results
        if trimmed.isEmpty {
            updateResultsImmediate()
            return
        }
        
        // For short queries (1-2 chars), search immediately to feel responsive
        // For longer queries (likely still typing), debounce
        let debounceMs: UInt64 = trimmed.count <= 2 ? 0 : 100_000_000  // 0ms or 100ms
        
        if debounceMs == 0 {
            performSearch()
        } else {
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: debounceMs)
                guard !Task.isCancelled else { return }
                performSearch()
            }
        }
    }
    
    private func updateResultsImmediate() {
        selectedIndex = 0
        
        if let filter = selectedFilter {
            results = allEntries.lazy.filter { $0.contentType == filter }.prefix(9).map { $0 }
        } else {
            results = Array(allEntries.prefix(9))
        }
    }
    
    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            updateResultsImmediate()
            return
        }
        
        selectedIndex = 0
        
        // Use pre-built index for fast search
        if let index = searchIndex {
            let matches = index.search(
                query: trimmed,
                contentType: selectedFilter,
                limit: 20,
                fuse: fuse
            )
            results = matches
        } else {
            // Fallback to simple contains search if index not ready
            let lower = trimmed.lowercased()
            var filtered = allEntries.filter { $0.content.lowercased().contains(lower) }
            if let filter = selectedFilter {
                filtered = filtered.filter { $0.contentType == filter }
            }
            results = Array(filtered.prefix(20))
        }
    }
}

// MARK: - Pre-built Search Index

/// Pre-processes entries for fast searching (not an actor - synchronous access)
private final class SearchIndex: @unchecked Sendable {
    private struct IndexedEntry {
        let entry: ClipboardEntry
        let lowercaseContent: String
        let contentLength: Int
    }
    
    private let indexedEntries: [IndexedEntry]
    
    init(entries: [ClipboardEntry]) {
        // Pre-compute lowercase content for fast exact/contains matching
        // Only index first 500 entries for performance
        self.indexedEntries = entries.prefix(500).map { entry in
            IndexedEntry(
                entry: entry,
                lowercaseContent: entry.content.lowercased(),
                contentLength: entry.content.count
            )
        }
    }
    
    func search(
        query: String,
        contentType: ContentType?,
        limit: Int,
        fuse: Fuse
    ) -> [ClipboardEntry] {
        let lowerQuery = query.lowercased()
        
        var exactMatches: [(ClipboardEntry, Double)] = []
        var containsMatches: [(ClipboardEntry, Double)] = []
        var fuzzyMatches: [(ClipboardEntry, Double)] = []
        
        // Create pattern once
        let pattern = fuse.createPattern(from: query)
        
        for indexed in indexedEntries {
            // Apply content type filter
            if let filter = contentType, indexed.entry.contentType != filter {
                continue
            }
            
            // Exact match
            if indexed.lowercaseContent == lowerQuery {
                exactMatches.append((indexed.entry, 0.0))
                continue
            }
            
            // Contains match
            if indexed.lowercaseContent.contains(lowerQuery) {
                let coverage = Double(query.count) / Double(indexed.contentLength)
                let score = 0.1 + (1.0 - coverage) * 0.2
                containsMatches.append((indexed.entry, score))
                continue
            }
            
            // Fuzzy match (only if we don't have enough results yet)
            if exactMatches.count + containsMatches.count < limit {
                if let result = fuse.search(pattern, in: indexed.entry.content) {
                    if result.score <= 0.6 {
                        fuzzyMatches.append((indexed.entry, 0.4 + result.score))
                    }
                }
            }
        }
        
        // Sort and combine
        exactMatches.sort { $0.0.timestamp > $1.0.timestamp }
        containsMatches.sort { $0.1 < $1.1 }
        fuzzyMatches.sort { $0.1 < $1.1 }
        
        var results: [ClipboardEntry] = []
        results.append(contentsOf: exactMatches.map(\.0))
        results.append(contentsOf: containsMatches.map(\.0))
        results.append(contentsOf: fuzzyMatches.map(\.0))
        
        return Array(results.prefix(limit))
    }
}
