#if os(macOS)
import Foundation
import PastaCore
@testable import PastaSync

final class MemoryTailnetCredentials: TailnetCredentials, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]
    func read(_ id: UUID) throws -> String? { lock.lock(); defer { lock.unlock() }; return tokens[id] }
    func save(_ token: String, id: UUID) throws { lock.lock(); defer { lock.unlock() }; tokens[id] = token }
    func remove(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; tokens.removeValue(forKey: id) }
}
actor TailnetTestNetwork {
    var engines: [String: TailnetEngine] = [:]
    var devices: [TailnetDevice] = []
    var offline: Set<String> = []
    var chunks = 0
    var pauseNextChunk = false
    var paused: CheckedContinuation<Void, Never>?
    var pauseObserver: CheckedContinuation<Void, Never>?
    var breakAfterChunk: Int?
    var clipboardWrites: [String: [UUID]] = [:]
    func register(_ engine: TailnetEngine, device: TailnetDevice) { engines[device.address] = engine; devices.append(device) }
    func inventory(_ local: TailnetDevice) -> TailnetInventory {
        TailnetInventory(local: local, peers: devices.filter { $0.id != local.id }.map { d in var d = d; d.online = !offline.contains(d.id); return d })
    }
    func send(_ request: TailnetRequest, target: String, source: String) async throws -> TailnetResponse {
        guard let engine = engines[target], !offline.contains(devices.first(where: { $0.address == target })?.id ?? "") else { throw URLError(.notConnectedToInternet) }
        if request.operation == .chunk {
            chunks += 1
            if pauseNextChunk {
                pauseNextChunk = false
                await withCheckedContinuation { continuation in
                    paused = continuation; pauseObserver?.resume(); pauseObserver = nil
                }
            }
            if let stop = breakAfterChunk, chunks > stop { throw URLError(.networkConnectionLost) }
        }
        return await engine.handle(address: source, request: request)
    }
    func setOffline(_ id: String, _ value: Bool) { if value { offline.insert(id) } else { offline.remove(id) } }
    func pauseOnChunk() { pauseNextChunk = true }
    func waitForPause() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseObserver = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
    func interrupt(after: Int?) { breakAfterChunk = after }
    func record(_ id: UUID, on device: String, clipboard: Bool) { if clipboard { clipboardWrites[device, default: []].append(id) } }
}
struct TailnetTestNode {
    let device: TailnetDevice
    let db: DatabaseManager
    let engine: TailnetEngine
    let root: URL
    let credentials = MemoryTailnetCredentials()
    init(_ index: Int, network: TailnetTestNetwork, parent: URL, now: @escaping @Sendable () -> Date = { Date() }) async throws {
        device = TailnetDevice(id: "node-\(index)", name: "Mac \(index)", address: "100.64.0.\(index)")
        root = parent.appendingPathComponent("node-\(index)")
        db = try DatabaseManager(databaseURL: root.appendingPathComponent("history.sqlite"))
        let device = device
        engine = try TailnetEngine(database: db, root: root.appendingPathComponent("files"), credentials: credentials, now: now,
                                  discover: { await network.inventory(device) },
                                  send: { request, target, source in try await network.send(request, target: target, source: source) },
                                  onReceived: { entry, replace in await network.record(entry.id, on: device.id, clipboard: replace) })
        await network.register(engine, device: device)
        await engine.setEnabled(true)
    }
    func tick() async { await engine.tick(listen: false) }
    func peer(_ other: Self) throws -> TailnetPeer { try TailnetStore(database: db).peers().first(where: { $0.id == other.device.id })! }
    func pair(_ other: Self) async throws {
        await tick(); await other.tick()
        try await engine.requestPairing(other.device.id)
        let request = try await other.engine.snapshot().requests.first!
        try await other.engine.approve(request.id, allow: true)
        await tick()
    }
}
#endif
