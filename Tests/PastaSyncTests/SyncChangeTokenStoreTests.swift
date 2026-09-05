import Foundation
import GRDB
import XCTest
@testable import PastaCore
@testable import PastaSync

final class SyncChangeTokenStoreTests: XCTestCase {
    @MainActor
    func testUpgradeIgnoresLegacyDefaultsThenReopensAndResetsDatabaseCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pasta.sqlite")
        let defaults = UserDefaults.standard
        let legacyKeys = ["com.pasta.sync.changeToken", "com.pasta.sync.appliedChangeToken.v1"]
        let previousValues = legacyKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(legacyKeys, previousValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in legacyKeys { defaults.set(Data([99]), forKey: key) }

        // Upgrade an existing schema without deleting its local history.
        let local = ClipboardEntry(content: "local pinned draft", contentType: .text, timestamp: Date(timeIntervalSince1970: 1_000), isPinned: true)
        try createLegacyDatabase(at: url, entry: local)
        var database: DatabaseManager? = try DatabaseManager(databaseURL: url)
        XCTAssertNil(try database!.loadSyncChangeToken())
        XCTAssertEqual(try database!.fetch(id: local.id), local)
        let downloaded = ClipboardEntry(content: "downloaded history", contentType: .text)
        let remote = CheckpointTestRemote(entry: downloaded)
        let service = SyncPullService(fetch: { try await remote.fetch(after: $0) })
        try await service.pull(into: database!)
        database = nil

        let reopened = try DatabaseManager(databaseURL: url)
        XCTAssertEqual(try reopened.loadSyncChangeToken(), Data([1]))
        XCTAssertEqual(try reopened.fetch(id: downloaded.id)?.content, downloaded.content)
        try await service.pull(into: reopened)
        XCTAssertEqual(try reopened.loadSyncChangeToken(), Data([2]), "An empty batch still advances its checkpoint")
        let inputs = await remote.fetchTokens
        XCTAssertEqual(inputs, [nil, Data([1])])

        let manager = SyncManager(syncEnabled: false)
        try manager.resetSync(in: reopened)
        XCTAssertNil(try reopened.loadSyncChangeToken())
        XCTAssertEqual(try reopened.countEntries(), 2, "Reset retains history for idempotent replay")
        try await service.pull(into: reopened)
        XCTAssertEqual(try reopened.countEntries(), 2)
        XCTAssertEqual(try reopened.fetch(id: local.id), local)
        XCTAssertEqual(try reopened.loadSyncChangeToken(), Data([1]))
    }

    func testRecreatedAndInMemoryDatabasesNeverInheritAnotherDatabaseCursor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncCheckpointLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pasta.sqlite")
        let downloaded = ClipboardEntry(content: "recoverable remote entry", contentType: .text)
        let remote = CheckpointTestRemote(entry: downloaded)
        let service = SyncPullService(fetch: { try await remote.fetch(after: $0) })
        var disk: DatabaseManager? = try DatabaseManager(databaseURL: url)
        try await service.pull(into: disk!)
        disk = nil
        try FileManager.default.removeItem(at: directory)

        let recreated = try DatabaseManager(databaseURL: url)
        XCTAssertNil(try recreated.loadSyncChangeToken())
        try await service.pull(into: recreated)
        XCTAssertNotNil(try recreated.fetch(id: downloaded.id))

        var fallback: DatabaseManager? = try DatabaseManager.inMemory()
        try await service.pull(into: fallback!)
        XCTAssertEqual(try fallback!.loadSyncChangeToken(), Data([1]))
        fallback = nil
        let nextFallback = try DatabaseManager.inMemory()
        XCTAssertNil(try nextFallback.loadSyncChangeToken())
        try await service.pull(into: nextFallback)
        XCTAssertNotNil(try nextFallback.fetch(id: downloaded.id))
        let inputs = await remote.fetchTokens
        XCTAssertEqual(inputs, [nil, nil, nil, nil])
    }

    private func createLegacyDatabase(at url: URL, entry: ClipboardEntry) throws {
        let writer = try DatabaseQueue(path: url.path)
        try DatabaseManager.migrator.migrate(writer, upTo: "addContentTypeMask")
        try DatabaseManager(dbWriter: writer).insert(entry)
    }
}

private actor CheckpointTestRemote {
    enum Failure: Error { case unexpectedCheckpoint }
    let entry: ClipboardEntry
    private(set) var fetchTokens: [Data?] = []

    init(entry: ClipboardEntry) { self.entry = entry }

    func fetch(after token: Data?) throws -> SyncChangeBatch {
        fetchTokens.append(token)
        if token == nil {
            return SyncChangeBatch(modified: [entry], deleted: [], token: Data([1]))
        }
        if token == Data([1]) {
            return SyncChangeBatch(modified: [], deleted: [], token: Data([2]))
        }
        throw Failure.unexpectedCheckpoint
    }
}
