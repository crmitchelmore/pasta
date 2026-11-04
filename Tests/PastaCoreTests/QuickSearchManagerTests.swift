import Combine
import XCTest
@testable import PastaCore

@MainActor
final class QuickSearchManagerTests: XCTestCase {
    func testCountsCoverEntireDatabaseAndExposeEveryNonemptyCategory() async throws {
        let database = try DatabaseManager.inMemory()
        let recent = (0..<1_200).map {
            ClipboardEntry(content: "recent \($0)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double(2_000 + $0)))
        }
        let older = ContentType.allCases.filter { $0 != .text }.map {
            ClipboardEntry(content: "older \($0.rawValue)", contentType: $0, timestamp: Date(timeIntervalSince1970: 1), isPinned: true)
        }
        try database.insertBatch(recent + older)
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), initialEntries: Array(recent.prefix(200)), database: database)

        try await waitUntil { manager.totalCount == recent.count + older.count }
        XCTAssertEqual(manager.pinnedCount, older.count)
        XCTAssertEqual(manager.availableFilters.count, ContentType.allCases.count)
        XCTAssertEqual(manager.availableFilters.first?.type, .text)
        XCTAssertEqual(manager.availableFilters.first?.count, 1_200)
        XCTAssertTrue(manager.availableFilters.filter { $0.type != .text }.allSatisfy { $0.count == 1 })

        manager.prepareForSearch()
        try await waitUntil { !manager.isUsingLoadedHistory && manager.results.count == 50 }
        XCTAssertEqual(manager.resultSummary, "Up to 50 recent items · all history")
    }

    func testCountsRefreshAfterInsertPinReclassificationAndDeletionWithSameLoadedWindow() async throws {
        let database = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "original", contentType: .text)
        try database.insert(entry)
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), database: database)
        try await waitUntil { manager.totalCount == 1 }

        try database.setPinned(id: entry.id, pinned: true)
        publisher.send([])
        try await waitUntil { manager.pinnedCount == 1 }
        XCTAssertTrue(try database.applyClassification(matching: entry, contentType: .prose, metadata: nil, extractedEntries: []))
        publisher.send([])
        try await waitUntil { manager.availableFilters == [.init(type: .prose, count: 1)] }
        XCTAssertEqual(manager.totalCount, 1)

        let inserted = ClipboardEntry(content: "new URL", contentType: .url)
        try database.insert(inserted)
        publisher.send([])
        try await waitUntil { manager.totalCount == 2 }
        XCTAssertEqual(Set(manager.availableFilters.map(\.type)), [.prose, .url])

        try database.delete(id: entry.id)
        publisher.send([])
        try await waitUntil { manager.totalCount == 1 && manager.pinnedCount == 0 }
        XCTAssertEqual(manager.availableFilters, [.init(type: .url, count: 1)])
        try database.delete(id: inserted.id)
        publisher.send([])
        try await waitUntil { manager.totalCount == 0 }
        XCTAssertTrue(manager.availableFilters.isEmpty)
    }

    func testOpeningSearchRefreshesCountsAfterAnotherConnectionWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let database = try DatabaseManager(databaseURL: url)
        let externalWriter = try DatabaseManager(databaseURL: url)
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), database: database)
        try await waitUntil { manager.totalCount == 0 }

        try externalWriter.insert(ClipboardEntry(content: "external", contentType: .email, isPinned: true))
        manager.prepareForSearch()
        try await waitUntil { manager.totalCount == 1 }
        XCTAssertEqual(manager.pinnedCount, 1)
        XCTAssertEqual(manager.availableFilters, [.init(type: .email, count: 1)])
        try await waitUntil { manager.results.count == 1 && !manager.isUsingLoadedHistory }
    }

    func testBlankFiltersAndSearchReachOlderRowsOutsideLoadedWindowWithBoundedResults() async throws {
        let database = try DatabaseManager.inMemory()
        let recent = (0..<1_100).map {
            ClipboardEntry(content: "recent \($0)", contentType: .text, timestamp: Date(timeIntervalSince1970: Double(2_000 + $0)))
        }
        let older = (0..<60).map {
            ClipboardEntry(content: "needle \($0)", contentType: .url, timestamp: Date(timeIntervalSince1970: Double($0)), isPinned: $0 < 30)
        }
        try database.insertBatch(recent + older)
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), initialEntries: Array(recent.prefix(200)), database: database)
        manager.selectedFilter = .url
        manager.searchQueryChanged()
        try await waitUntil { !manager.isUsingLoadedHistory && manager.results.count == 50 }
        XCTAssertTrue(manager.results.allSatisfy { $0.contentType == .url })
        XCTAssertEqual(manager.results.first?.id, older.last?.id)

        manager.showPinnedOnly = true
        manager.searchQueryChanged()
        try await waitUntil { !manager.isUsingLoadedHistory && manager.results.count == 30 }
        XCTAssertTrue(manager.results.allSatisfy(\.isPinned))

        manager.query = "needle"
        manager.searchQueryChanged()
        try await waitUntil { manager.results.count == 20 }
        XCTAssertTrue(manager.results.allSatisfy { $0.isPinned && $0.contentType == .url })
        XCTAssertEqual(manager.resultSummary, "Up to 20 matches · all history")
        XCTAssertEqual(manager.results.map(\.id), try database.searchFTS(query: "needle", contentType: .url, limit: 20, pinnedOnly: true).map(\.id))
    }

    func testSameSizeEntryPublicationRefreshesActiveSearch() async throws {
        let database = try DatabaseManager.inMemory()
        let entry = ClipboardEntry(content: "needle", contentType: .text)
        try database.insert(entry)
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), initialEntries: [entry], database: database)
        manager.selectedFilter = .prose
        manager.query = "needle"
        manager.searchQueryChanged()
        try await waitUntil { !manager.isUsingLoadedHistory && manager.results.isEmpty }

        XCTAssertTrue(try database.applyClassification(matching: entry, contentType: .prose, metadata: nil, extractedEntries: []))
        var updated = entry
        updated.contentType = .prose
        publisher.send([updated])
        try await waitUntil { manager.results.map(\.id) == [entry.id] }
        XCTAssertEqual(manager.results.first?.contentType, .prose)
    }

    func testNoDatabaseCountsAllLoadedRowsAndRefreshesSameSizeChanges() async throws {
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        var entries = (0..<1_100).map { ClipboardEntry(content: "fallback \($0)", contentType: .text) }
        entries.append(ClipboardEntry(content: "rare", contentType: .url, isPinned: true))
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), initialEntries: entries)
        try await waitUntil { manager.totalCount == 1_101 }
        XCTAssertEqual(manager.pinnedCount, 1)
        XCTAssertEqual(manager.availableFilters, [.init(type: .text, count: 1_100), .init(type: .url, count: 1)])
        manager.selectedFilter = .url
        manager.searchQueryChanged()
        try await waitUntil { manager.results.count == 1 }
        XCTAssertEqual(manager.resultSummary, "Up to 50 recent items · loaded history only")

        entries[1_100].contentType = .email
        entries[1_100].isPinned = false
        publisher.send(entries)
        try await waitUntil { manager.pinnedCount == 0 && manager.availableFilters.contains(.init(type: .email, count: 1)) }
        XCTAssertFalse(manager.availableFilters.contains { $0.type == .url })
        manager.query = "fallback"
        manager.selectedFilter = nil
        manager.searchQueryChanged()
        try await waitUntil { manager.results.count == 20 }
        XCTAssertEqual(manager.resultSummary, "Up to 20 matches · loaded history only")
    }

    func testSupersededRecentFetchDoesNotReplaceNewFilterOrCommandResults() async throws {
        let database = try DatabaseManager.inMemory()
        try database.insertBatch([
            ClipboardEntry(content: "text", contentType: .text),
            ClipboardEntry(content: "URL", contentType: .url)
        ])
        let publisher = PassthroughSubject<[ClipboardEntry], Never>()
        let manager = QuickSearchManager()
        manager.initialize(entriesPublisher: publisher.eraseToAnyPublisher(), database: database)
        manager.selectedFilter = .text
        manager.searchQueryChanged()
        manager.selectedFilter = .url
        manager.searchQueryChanged()
        try await waitUntil { manager.results.count == 1 && !manager.isUsingLoadedHistory }
        XCTAssertEqual(manager.results.first?.contentType, .url)

        manager.prepareForSearch()
        manager.query = "!"
        manager.searchQueryChanged()
        publisher.send([])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(manager.isCommandMode)
        XCTAssertTrue(manager.results.isEmpty)
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Quick Search state did not update", file: file, line: line)
    }
}
