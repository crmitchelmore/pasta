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
    @Published public var showPinnedOnly: Bool = false
    @Published public private(set) var results: [ClipboardEntry] = []
    @Published public var selectedIndex: Int = 0
    @Published public private(set) var availableFilters: [FilterInfo] = []
    @Published public private(set) var pinnedCount: Int = 0
    @Published public private(set) var isReady: Bool = false
    
    // Command mode state
    @Published public private(set) var isCommandMode: Bool = false
    @Published public private(set) var commandResults: [Command] = []
    
    public struct FilterInfo: Equatable, Sendable {
        public let type: ContentType
        public let count: Int
    }
    
    // MARK: - Private State
    
    private var allEntries: [ClipboardEntry] = []
    private var entriesSubscription: AnyCancellable?
    private var searchDebounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pinnedCountTask: Task<Void, Never>?
    
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
        showPinnedOnly = false
        selectedIndex = 0
        isCommandMode = false
        commandResults = []
        results = Array(allEntries.prefix(50))
        PastaLogger.search.debug("prepareForSearch: allEntries=\(allEntries.count), results=\(results.count)")
    }
    
    /// Move selection up or down
    public func moveSelection(by delta: Int) {
        let maxIndex: Int
        if isCommandMode {
            maxIndex = min(commandResults.count, 9) - 1
        } else {
            maxIndex = results.count - 1
        }
        guard maxIndex >= 0 else { return }
        selectedIndex = max(0, min(maxIndex, selectedIndex + delta))
    }
    
    /// Get the currently selected entry (for clipboard mode)
    public var selectedEntry: ClipboardEntry? {
        guard !isCommandMode, selectedIndex >= 0 && selectedIndex < results.count else { return nil }
        return results[selectedIndex]
    }
    
    /// Get the currently selected command (for command mode)
    public var selectedCommand: Command? {
        guard isCommandMode, selectedIndex >= 0 && selectedIndex < commandResults.count else { return nil }
        return commandResults[selectedIndex]
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

        // Pinned counts are typically tiny but pinned items are often older than
        // the 1000-entry sample. Prefer the database for an accurate total; fall
        // back to a full scan when the database isn't available (tests). Both
        // run off the main actor: this is called on every entries publish.
        pinnedCountTask?.cancel()
        let database = database
        let snapshot = allEntries
        pinnedCountTask = Task { [weak self] in
            let count = await Task.detached(priority: .utility) { () -> Int in
                if let database {
                    do {
                        return try database.pinnedCount()
                    } catch {
                        PastaLogger.search.error("pinnedCount() failed: \(error.localizedDescription)")
                    }
                }
                return snapshot.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
            }.value
            guard !Task.isCancelled else { return }
            self?.pinnedCount = count
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
        searchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for command mode (query starts with !)
        if trimmed.hasPrefix("!") {
            isCommandMode = true
            let commandQuery = String(trimmed.dropFirst())
            commandResults = CommandRegistry.shared.search(query: commandQuery)
            selectedIndex = 0
            results = []
            return
        }
        
        // Exit command mode if no longer starting with !
        if isCommandMode {
            isCommandMode = false
            commandResults = []
        }
        
        // Empty query = immediate results
        if trimmed.isEmpty {
            updateResultsImmediate()
            return
        }
        
        // Short queries (1-2 chars) are the broadest prefix scans, so they get the
        // longest debounce — running them on every keystroke queues expensive work
        // that the next keystroke immediately invalidates.
        let debounceNanoseconds: UInt64 = trimmed.count <= 2 ? 50_000_000 : 25_000_000  // 50ms or 25ms

        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }
    
    private func updateResultsImmediate() {
        selectedIndex = 0

        results = Array(allEntries.lazy
            .filter { !self.showPinnedOnly || $0.isPinned }
            .filter { self.selectedFilter == nil || $0.contentType == self.selectedFilter }
            .prefix(50))
    }
    
    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            updateResultsImmediate()
            return
        }
        
        selectedIndex = 0

        let querySnapshot = trimmed
        let filterSnapshot = selectedFilter
        let pinnedSnapshot = showPinnedOnly
        let dbSnapshot = database
        let entriesSnapshot = allEntries

        searchTask?.cancel()
        searchTask = Task {
            let searchResult = await withCancellableDetachedTask(priority: .userInitiated) { () -> [ClipboardEntry]? in
                // A superseded query must not keep the DB queue busy.
                guard !Task.isCancelled else { return nil }

                if let dbSnapshot {
                    do {
                        let startTime = CFAbsoluteTimeGetCurrent()
                        let matches = try dbSnapshot.searchFTS(query: querySnapshot, contentType: filterSnapshot, limit: 20, pinnedOnly: pinnedSnapshot)
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        PastaLogger.search.debug("FTS5 search '\(querySnapshot)': \(matches.count) results in \(String(format: "%.1f", elapsed))ms")
                        return matches
                    } catch {
                        PastaLogger.search.error("FTS5 search failed: \(error.localizedDescription)")
                    }
                }

                guard !Task.isCancelled else { return nil }
                return Self.fallbackMatches(query: querySnapshot, entries: entriesSnapshot, filter: filterSnapshot, pinnedOnly: pinnedSnapshot)
            }

            guard !Task.isCancelled, let searchResult else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == querySnapshot else { return }
            guard selectedFilter == filterSnapshot else { return }
            guard showPinnedOnly == pinnedSnapshot else { return }
            results = searchResult
        }
    }

    private nonisolated static func fallbackMatches(query: String, entries: [ClipboardEntry], filter: ContentType?, pinnedOnly: Bool) -> [ClipboardEntry] {
        let lower = query.lowercased()
        let filtered = entries.lazy.filter {
            $0.content.lowercased().contains(lower)
                && (filter == nil || $0.contentType == filter)
                && (!pinnedOnly || $0.isPinned)
        }
        return Array(filtered.prefix(20))
    }
}
