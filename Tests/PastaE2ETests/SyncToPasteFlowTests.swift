import AppKit
import Foundation
import XCTest
import PastaSync
@testable import PastaCore

/// The real pull coordinator, disk transaction, FTS search and paste service;
/// only the remote transport and system pasteboard are substituted.
final class SyncToPasteFlowTests: XCTestCase {
    @MainActor
    func testDownloadedTextCanBeFoundCopiedUpdatedAndDeletedAfterReopening() async throws {
        let env = try E2ETempEnvironment(name: "sync-text")
        defer { env.destroy() }
        var database: DatabaseManager? = try env.openDatabase()
        let downloaded = ClipboardEntry(content: "aardvark release notes", contentType: .text, copyCount: 3)
        let updated = ClipboardEntry(
            id: downloaded.id, content: "pangolin deployment guide", contentType: .text, copyCount: 5
        )
        let local = ClipboardEntry(
            content: "unrelated local draft", contentType: .text,
            timestamp: Date(timeIntervalSince1970: 1_000), isPinned: true
        )
        try database!.insert(local)
        let remote = SyncJourneyRemote(batches: [
            SyncChangeBatch(modified: [downloaded], deleted: [], token: Data([1])),
            SyncChangeBatch(modified: [updated], deleted: [], token: Data([2])),
            SyncChangeBatch(modified: [], deleted: [downloaded.id], token: Data([3]))
        ])
        let manager = SyncManager(pullService: SyncPullService(
            fetch: { _ in try await remote.fetch() }, acknowledge: { try await remote.acknowledge($0) }
        ))
        let writer = E2EPasteboardWriter()
        let paste = PasteService(pasteboard: writer, simulator: E2EPasteSimulator())

        try await manager.pullChanges(into: database!)

        let initialHits = try SearchService(database: database!).search(query: "aardvark")
        XCTAssertEqual(initialHits.map(\.entry.id), [downloaded.id])
        let initialMatch = try XCTUnwrap(initialHits.first)
        XCTAssertFalse(initialMatch.ranges.isEmpty)
        XCTAssertTrue(initialMatch.entry.isSynced)
        XCTAssertEqual(initialMatch.entry.copyCount, 3)
        XCTAssertTrue(paste.copy(initialMatch.entry))
        XCTAssertEqual(writer.lastWrite, .text(downloaded.content))
        XCTAssertEqual(manager.syncState, .idle)
        XCTAssertNotNil(manager.lastSyncDate)

        try await manager.pullChanges(into: database!)

        do {
            let search = SearchService(database: database!)
            XCTAssertTrue(try search.search(query: "aardvark").isEmpty)
            let updatedHits = try search.search(query: "pangolin")
            XCTAssertEqual(updatedHits.map(\.entry.id), [downloaded.id])
            let updatedMatch = try XCTUnwrap(updatedHits.first)
            XCTAssertEqual(updatedMatch.entry.copyCount, 5)
            XCTAssertTrue(paste.paste(updatedMatch.entry))
            XCTAssertEqual(writer.lastWrite, .text(updated.content))
            XCTAssertEqual(try database!.countEntries(), 2)

            try await manager.pullChanges(into: database!)
            XCTAssertNil(try database!.fetch(id: downloaded.id))
            XCTAssertTrue(try search.search(query: "pangolin").isEmpty)
        }

        // A fresh connection must see the durable delete and the updated FTS index.
        database = nil
        let reopened = try env.openDatabase()
        XCTAssertNil(try reopened.fetch(id: downloaded.id))
        XCTAssertTrue(try SearchService(database: reopened).search(query: "aardvark").isEmpty)
        XCTAssertTrue(try SearchService(database: reopened).search(query: "pangolin").isEmpty)
        XCTAssertEqual(try reopened.fetch(id: local.id), local)
        XCTAssertEqual(try reopened.fetchUnsynced().map(\.id), [local.id])
        XCTAssertEqual(try reopened.countEntries(), 1)
        let tokens = await remote.acknowledgedTokens
        XCTAssertEqual(tokens, [Data([1]), Data([2]), Data([3])])
    }

    @MainActor
    func testDownloadedImageUpdatePastesNewBytesInsteadOfCachedLocalImage() async throws {
        let env = try E2ETempEnvironment(name: "sync-image")
        defer { env.destroy() }
        let database = try env.openDatabase()
        let oldBytes = try tiffFixture(red: 255, green: 0, blue: 0)
        let newBytes = try tiffFixture(red: 0, green: 0, blue: 255)
        XCTAssertNotEqual(oldBytes, newBytes)
        XCTAssertTrue(try XCTUnwrap(NSImage(data: oldBytes)).isValid)
        XCTAssertTrue(try XCTUnwrap(NSImage(data: newBytes)).isValid)
        let cachedPath = try env.openImageStorage().saveImage(oldBytes)
        let local = ClipboardEntry(content: "aardvark screenshot", contentType: .image, imagePath: cachedPath)
        try database.insert(local)
        let downloaded = ClipboardEntry(
            id: local.id, content: "pangolin screenshot", contentType: .screenshot, rawData: newBytes
        )
        let remote = SyncJourneyRemote(batches: [SyncChangeBatch(
            modified: [downloaded], deleted: [], token: Data([1])
        )])
        let manager = SyncManager(pullService: SyncPullService(
            fetch: { _ in try await remote.fetch() }, acknowledge: { try await remote.acknowledge($0) }
        ))

        try await manager.pullChanges(into: database)

        let search = SearchService(database: database)
        XCTAssertTrue(try search.search(query: "aardvark").isEmpty)
        let hit = try XCTUnwrap(try search.search(query: "pangolin", contentType: .screenshot).first)
        XCTAssertEqual(hit.entry.id, local.id)
        XCTAssertNil(hit.entry.imagePath)
        XCTAssertEqual(hit.entry.rawData, newBytes)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let paste = PasteService(
            pasteboard: SystemPasteboardWriter(pasteboard: pasteboard), simulator: E2EPasteSimulator()
        )
        XCTAssertTrue(paste.paste(hit.entry))
        let pastedBytes = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertEqual(pastedBytes, newBytes)
        XCTAssertTrue(try XCTUnwrap(NSImage(data: pastedBytes)).isValid)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: pastedBytes))
        XCTAssertEqual(decoded.pixelsWide, 2)
        XCTAssertEqual(decoded.pixelsHigh, 2)
        let pixel = try XCTUnwrap(decoded.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(pixel.redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(pixel.blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try database.countEntries(), 1)
        XCTAssertEqual(try database.unsyncedCount(), 0)
    }

    @MainActor
    private func tiffFixture(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 8, bitsPerPixel: 32
        ))
        // Write explicit RGBA samples: setColor left both fixtures with identical
        // empty pixels on the headless CI runner, so no image update was tested.
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<2 {
            for x in 0..<2 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = 255
            }
        }
        let data = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(decoded.pixelsWide, 2)
        XCTAssertEqual(decoded.pixelsHigh, 2)
        for y in 0..<2 {
            for x in 0..<2 {
                let pixel = try XCTUnwrap(decoded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(pixel.redComponent, CGFloat(red) / 255, accuracy: 0.01)
                XCTAssertEqual(pixel.greenComponent, CGFloat(green) / 255, accuracy: 0.01)
                XCTAssertEqual(pixel.blueComponent, CGFloat(blue) / 255, accuracy: 0.01)
                XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
            }
        }
        return data
    }
}

private actor SyncJourneyRemote {
    enum Failure: Error { case unexpectedFetch, unexpectedToken }
    private let batches: [SyncChangeBatch]
    private var index = 0
    private(set) var acknowledgedTokens: [Data] = []

    init(batches: [SyncChangeBatch]) { self.batches = batches }

    func fetch() throws -> SyncChangeBatch {
        guard index < batches.count else { throw Failure.unexpectedFetch }
        return batches[index]
    }

    func acknowledge(_ token: Data) throws {
        guard index < batches.count, batches[index].token == token else { throw Failure.unexpectedToken }
        acknowledgedTokens.append(token)
        index += 1
    }
}
