import AppKit
import Foundation
import XCTest
import PastaCore
import PastaDetectors
@testable import PastaSync

/// Two real TCP listeners, independent disk histories, actual approved pairing,
/// capture enrichment, chunk transfer, search and named system pasteboard. Only
/// Tailscale inventory/addresses and Keychain are replaced; no personal clipboard.
final class TailnetToPasteFlowTests: XCTestCase {
    @MainActor
    func testApprovedTCPPeersTransferCapturedRichTextAndFilesThroughSearchAndPaste() async throws {
        let first = try E2ETempEnvironment(name: "tailnet-a")
        let second = try E2ETempEnvironment(name: "tailnet-b")
        defer { first.destroy(); second.destroy() }
        let aDB = try first.openDatabase(), bDB = try second.openDatabase()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TailnetTCPJourney-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let aDevice = TailnetDevice(id: "a", name: "First Mac", address: "100.64.0.1")
        let bDevice = TailnetDevice(id: "b", name: "Second Mac", address: "100.64.0.2")
        let ports = JourneyPorts()
        let sender: TailnetEngine.Send = { request, destination, _ in
            let port = await ports.get(destination)
            return try await TailnetTransport.request(request, address: "127.0.0.1", port: port)
        }
        let a = try TailnetEngine(database: aDB, root: scratch.appendingPathComponent("a"), credentials: JourneyKeys(),
                                  discover: { TailnetInventory(local: aDevice, peers: [bDevice]) }, send: sender)
        let b = try TailnetEngine(database: bDB, root: scratch.appendingPathComponent("b"), credentials: JourneyKeys(),
                                  discover: { TailnetInventory(local: bDevice, peers: [aDevice]) }, send: sender)
        let aListener = TailnetTransport(), bListener = TailnetTransport()
        defer { aListener.stop(); bListener.stop() }
        let aPort = try await aListener.listen(address: "127.0.0.1", port: 0) { _, request in await a.handle(address: bDevice.address, request: request) }
        let bPort = try await bListener.listen(address: "127.0.0.1", port: 0) { _, request in await b.handle(address: aDevice.address, request: request) }
        await ports.set(aDevice.address, aPort); await ports.set(bDevice.address, bPort)
        await a.setEnabled(true); await b.setEnabled(true)
        await a.tick(listen: false); await b.tick(listen: false)
        try await a.requestPairing(bDevice.id)
        let request = try await b.snapshot().requests.first!
        try await b.approve(request.id, allow: true)
        await a.tick(listen: false)

        let rich = NSAttributedString(string: "aardvark tailnet journey", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pipeline = E2ECapturePipeline(database: aDB, imageStorage: try first.openImageStorage(), detector: ContentTypeDetector())
        let captured = try pipeline.ingest(ClipboardEntry(content: rich.string, contentType: .text, rawData: rtf)).persisted.first!
        await a.tick(listen: false)
        let result = try XCTUnwrap(SearchService(database: bDB).search(query: "aardvark").first?.entry)
        XCTAssertEqual(result.id, captured.id)
        XCTAssertTrue(result.receivedViaTailnet)
        XCTAssertFalse(result.cloudSyncAllowed)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TailnetJourney-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let paste = PasteService(pasteboard: SystemPasteboardWriter(pasteboard: pasteboard), simulator: E2EPasteSimulator())
        XCTAssertTrue(paste.copy(result))
        XCTAssertEqual(pasteboard.string(forType: .string), rich.string)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        pasteboard.setString("1", forType: .pastaTailnetReceived)
        XCTAssertNil(SystemPasteboard(pasteboard: pasteboard).readContents(), "Automatic received clipboard writes cannot be recaptured")

        let source = scratch.appendingPathComponent("sample\nfile.txt")
        let bytes = Data(repeating: 0x51, count: 700_000)
        try bytes.write(to: source)
        let file = try pipeline.ingest(ClipboardEntry(content: source.path, contentType: .filePath, rawData: try JSONEncoder().encode([source.path]))).persisted.first!
        await a.tick(listen: false)
        let received = try XCTUnwrap(bDB.fetch(id: file.id))
        XCTAssertTrue(paste.copy(received))
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.count, 1)
        XCTAssertNotEqual(urls[0], source)
        XCTAssertEqual(try Data(contentsOf: urls[0]), bytes)
        XCTAssertEqual(try bDB.unsyncedCount(), 0)
        try bDB.delete(id: file.id)
        await b.setEnabled(false); await b.tick(listen: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
private actor JourneyPorts {
    var ports: [String: UInt16] = [:]
    func get(_ address: String) -> UInt16 { ports[address]! }
    func set(_ address: String, _ port: UInt16) { ports[address] = port }
}
private final class JourneyKeys: TailnetCredentials, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]
    func read(_ id: UUID) throws -> String? { lock.lock(); defer { lock.unlock() }; return tokens[id] }
    func save(_ token: String, id: UUID) throws { lock.lock(); defer { lock.unlock() }; tokens[id] = token }
    func remove(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; tokens.removeValue(forKey: id) }
}
