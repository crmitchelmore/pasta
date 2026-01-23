import Combine
import Foundation

/// Singleton manager that keeps quick search data pre-indexed and ready.
/// This ensures instant appearance when the hotkey is pressed.
/// Uses SQLite FTS5 for blazing fast search (sub-10ms for 10k+ entries).
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
    
    // Database reference for FTS5 search
    private var database: DatabaseManager?
    
    private init() {}
    
    // MARK: - Public API
    
    /// Call once at app startup to begin indexing
    public func initialize(entriesPublisher: AnyPublisher<[ClipboardEntry], Never>, initialEntries: [ClipboardEntry] = [], database: DatabaseManager? = nil) {
        PastaLogger.search.debug("QuickSearchManager.initialize called: initialEntries=\(initialEntries.count)")
        
        self.database = database
        
        // Load initial entries immediately (don't wait for publisher)
        if !initialEntries.isEmpty {
            updateEntries(initialEntries)
        }
        
        entriesSubscription = entriesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                PastaLogger.search.debug("QuickSearchManager received from publisher: \(entries.count) entries")
                self?.updateEntries(entries)
            }
    }
    
    /// Reset state for fresh search (call when showing quick search)
    public func prepareForSearch() {
        query = ""
        selectedFilter = nil
        selectedIndex = 0
        results = Array(allEntries.prefix(9))
        PastaLogger.search.debug("prepareForSearch: allEntries=\(allEntries.count), results=\(results.count)")
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
        isReady = true
        PastaLogger.search.debug("Entries updated: \(entries.count) entries (FTS5 search ready)")
        
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
        let debounceMs: UInt64 = trimmed.count <= 2 ? 0 : 25_000_000  // 0ms or 25ms
        
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
        
        // Use FTS5 for blazing fast search (runs in SQLite's optimized C engine)
        if let database = database {
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                let matches = try database.searchFTS(query: trimmed, contentType: selectedFilter, limit: 20)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                PastaLogger.search.debug("FTS5 search '\(trimmed)': \(matches.count) results in \(String(format: "%.1f", elapsed))ms")
                results = matches
            } catch {
                PastaLogger.search.error("FTS5 search failed: \(error.localizedDescription)")
                // Fallback to simple contains search
                fallbackSearch(trimmed)
            }
        } else {
            // Fallback to simple contains search if database not available
            fallbackSearch(trimmed)
        }
    }
    
    private func fallbackSearch(_ query: String) {
        let lower = query.lowercased()
        var filtered = allEntries.filter { $0.content.lowercased().contains(lower) }
        if let filter = selectedFilter {
            filtered = filtered.filter { $0.contentType == filter }
        }
        results = Array(filtered.prefix(20))
    }
}
