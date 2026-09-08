#if os(macOS)
import Foundation
import PastaCore

public struct TailnetPairingRequest: Identifiable, Sendable {
    public var id: UUID
    public var device: TailnetDevice
    public var expires: Date
}
struct TailnetSnapshot: Sendable {
    var status: String
    var devices: [TailnetDevice]
    var peers: [TailnetPeer]
    var requests: [TailnetPairingRequest]
    var transfers: [TailnetTransfer]
}

actor TailnetEngine {
    typealias Discover = @Sendable () async throws -> TailnetInventory
    typealias Send = @Sendable (TailnetRequest, String, String) async throws -> TailnetResponse
    let store: TailnetStore
    let files: TailnetFiles
    let credentials: any TailnetCredentials
    private let now: @Sendable () -> Date
    private let discover: Discover
    private let send: Send
    private let onReceived: @Sendable (ClipboardEntry, Bool) async -> Void
    private let transport = TailnetTransport()
    private var inventory: TailnetInventory?
    private var listeningAddress: String?
    private var enabled = false
    private var generation = UUID()
    private var busy = false
    private var preparation: (peerID: String, task: Task<TailnetPrepared, Error>)?
    private var finalising: [UUID: Task<ClipboardEntry, Error>] = [:]
    private var status = "Off"
    private var available: [TailnetDevice] = []
    private var pending: [UUID: (request: TailnetPairingRequest, token: String)] = [:]
    private var requestedAt: [String: Date] = [:]
    private var incoming: [UUID: (peer: String, pairing: UUID, manifest: TailnetManifest)] = [:]
    private var outgoing: [String: (device: TailnetDevice, pairing: UUID, token: String, expires: Date)] = [:]

    init(database: DatabaseManager, root: URL, credentials: any TailnetCredentials = TailnetKeychain(),
         now: @escaping @Sendable () -> Date = { Date() },
         discover: @escaping Discover = { try await TailnetDiscovery.inventory() },
         send: @escaping Send = { request, address, local in try await TailnetTransport.request(request, address: address, localAddress: local) },
         onReceived: @escaping @Sendable (ClipboardEntry, Bool) async -> Void = { _, _ in }) throws {
        store = TailnetStore(database: database); files = try TailnetFiles(root: root)
        self.now = now; self.credentials = credentials; self.discover = discover; self.send = send; self.onReceived = onReceived
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; generation = UUID()
        if !value {
            preparation?.task.cancel()
            for task in finalising.values { task.cancel() }
            transport.stop(); listeningAddress = nil; inventory = nil; pending.removeAll(); incoming.removeAll(); outgoing.removeAll(); available = []; status = "Off" }
    }
    func snapshot() throws -> TailnetSnapshot {
        pending = pending.filter { $0.value.request.expires > now() }
        return TailnetSnapshot(status: status, devices: available, peers: try store.peers(), requests: pending.values.map(\.request).sorted { $0.expires < $1.expires }, transfers: try store.transfers(limit: 200))
    }
    func update(_ peer: TailnetPeer) throws {
        guard try store.peers().contains(where: { $0.id == peer.id && $0.pairingID == peer.pairingID }) else { throw TailnetError.denied }
        guard peer.approvalBytes >= 0, peer.approvalBytes <= 1_000_000_000_000,
              peer.receiveLimitBytes > 0, peer.receiveLimitBytes <= 1_000_000_000_000 else { throw TailnetError.invalid("Choose a limit between 1 MB and 1 TB.") }
        try store.save(peer)
        if !peer.sendEnabled, preparation?.peerID == peer.id { preparation?.task.cancel() }
    }
    func backfill(_ id: String) throws { try store.enqueue(for: id, backfill: true) }
    func decideTransfer(_ transfer: TailnetTransfer, approve: Bool) throws {
        // The displayed approval detail contains the payload digest. Approval is
        // valid only for that exact manifest, including file lengths/hashes.
        guard let current = try store.transfers(peerID: transfer.peerID, state: .approval, limit: 10000).first(where: { $0.id == transfer.id }),
              current.approvedDigest == transfer.approvedDigest else { throw TailnetError.denied }
        try store.setState(current, approve ? .pending : .declined)
    }
    func retry(_ transfer: TailnetTransfer) throws {
        guard let current = try store.transfers(peerID: transfer.peerID, state: .failed, limit: 10000).first(where: { $0.id == transfer.id }) else { throw TailnetError.denied }
        try store.setState(current, .pending)
    }

    func tick(listen: Bool = true) async {
        guard !busy else { return }
        do { try files.cleanup(database: store.database, active: Set(incoming.keys)) }
        catch { status = "Received-file cleanup needs attention. Check available storage and permissions." }
        guard enabled else { return }
        busy = true; defer { busy = false }
        let run = generation
        do {
            let fresh = try await discover()
            guard enabled, generation == run else { return }
            if inventory?.local.id != fresh.local.id { generation = UUID(); incoming.removeAll(); pending.removeAll(); outgoing.removeAll() }
            inventory = fresh
            if listen, listeningAddress != fresh.local.address {
                transport.stop()
                try await transport.listen(address: fresh.local.address) { [weak self] address, request in
                    guard let self else { return TailnetResponse(status: "denied") }
                    return await self.handle(address: address, request: request)
                }
                listeningAddress = fresh.local.address
            }
            status = "Connected to Tailscale"
            var found: [TailnetDevice] = []
            // Only query Tailscale's visible peer set, never scan a subnet.
            for device in fresh.peers where device.online {
                guard enabled else { return }
                if let reply = try? await send(TailnetRequest(operation: .hello), device.address, fresh.local.address),
                   reply.version == 1, reply.status == "hello", reply.device?.id == device.id { found.append(device) }
            }
            available = found
            for (id, attempt) in outgoing {
                guard attempt.expires > now() else { outgoing.removeValue(forKey: id); status = "Pairing request expired. Try again."; continue }
                var request = TailnetRequest(operation: .pairingStatus)
                request.pairingID = attempt.pairing; request.token = attempt.token
                guard let target = fresh.peers.first(where: { $0.id == id }), target.online else { continue }
                let response = try await send(request, target.address, fresh.local.address)
                if response.status == "approved" {
                    var peer = TailnetPeer(id: id, name: target.name, address: target.address, pairingID: attempt.pairing)
                    peer.localNodeID = fresh.local.id
                    try credentials.save(attempt.token, id: peer.pairingID)
                    try store.save(peer, newPair: true)
                    outgoing.removeValue(forKey: id)
                } else if response.status == "denied" { outgoing.removeValue(forKey: id); status = "Pairing declined or expired." }
            }
            for var peer in try store.peers() where peer.localNodeID == fresh.local.id {
                guard enabled else { return }
                guard let device = fresh.peers.first(where: { $0.id == peer.id }), device.online else { continue }
                peer.address = device.address; peer.name = device.name
                try store.save(peer)
                guard peer.sendEnabled else { continue }
                try store.enqueue(for: peer.id)
                for transfer in try store.transfers(peerID: peer.id, state: .pending, limit: 32) {
                    guard enabled else { return }
                    do { try await transmit(transfer, to: peer) }
                    catch is CancellationError { return }
                    catch let error as TailnetError {
                        if case .timeout = error { status = error.localizedDescription; break }
                        try store.setState(transfer, .failed, detail: error.localizedDescription)
                    } catch {
                        // Network errors retry without poisoning the queue. File I/O
                        // errors become actionable failures and don't block later items.
                        if (error as NSError).domain == NSCocoaErrorDomain {
                            try store.setState(transfer, .failed, detail: "Source unavailable or storage could not be read. Restore the file, then Retry.")
                        } else { status = "Waiting for \(peer.name) to reconnect"; break }
                    }
                }
            }
            try files.cleanup(database: store.database, active: Set(incoming.keys))
        } catch {
            // Losing inventory means losing authority to listen or send.
            transport.stop(); listeningAddress = nil; inventory = nil; available = []
            status = (error as? TailnetError)?.localizedDescription ?? "Tailnet sync could not complete. Check Tailscale and storage, then retry."
        }
    }
    func requestPairing(_ id: String) async throws {
        guard enabled, let inventory, let device = inventory.peers.first(where: { $0.id == id && $0.online }),
              !(try store.peers()).contains(where: { $0.id == id }) else { throw TailnetError.denied }
        let pairing = UUID(), token = try TailnetKeychain.token()
        var request = TailnetRequest(operation: .pair); request.pairingID = pairing; request.token = token
        let response = try await send(request, device.address, inventory.local.address)
        guard response.status == "pending" else { throw TailnetError.unavailable("The target declined or is busy. Try again shortly.") }
        outgoing[id] = (device, pairing, token, now().addingTimeInterval(120))
        status = "Waiting for approval on \(device.name)"
    }
    func approve(_ id: UUID, allow: Bool) throws {
        guard let value = pending.removeValue(forKey: id), value.request.expires > now(), let inventory, enabled else { throw TailnetError.denied }
        guard allow else { return }
        var peer = TailnetPeer(id: value.request.device.id, name: value.request.device.name, address: value.request.device.address, pairingID: id)
        peer.localNodeID = inventory.local.id
        try credentials.save(value.token, id: id)
        do { try store.save(peer, newPair: true) }
        catch { try? credentials.remove(id); throw error }
    }
    func unpair(_ id: String) async throws {
        guard let peer = try store.peers().first(where: { $0.id == id }) else { return }
        let token = try credentials.read(peer.pairingID)
        // Local revocation is durable before any network await.
        try store.remove(id); try credentials.remove(peer.pairingID)
        if preparation?.peerID == id { preparation?.task.cancel() }
        for (entry, transfer) in incoming where transfer.peer == id { finalising[entry]?.cancel() }
        incoming = incoming.filter { $0.value.peer != id }; outgoing.removeValue(forKey: id)
        if let inventory, let device = inventory.peers.first(where: { $0.id == id }) {
            var request = TailnetRequest(operation: .revoke); request.pairingID = peer.pairingID; request.token = token
            _ = try? await send(request, device.address, inventory.local.address)
        }
    }
    private func authorised(_ request: TailnetRequest, device: TailnetDevice) throws -> TailnetPeer {
        guard let local = inventory?.local, let peer = try store.peers().first(where: { $0.id == device.id }),
              peer.localNodeID == local.id, request.pairingID == peer.pairingID,
              TailnetKeychain.matches(request.token, try credentials.read(peer.pairingID)) else { throw TailnetError.denied }
        return peer
    }
    func handle(address: String, request: TailnetRequest) async -> TailnetResponse {
        do {
            pending = pending.filter { $0.value.request.expires > now() }
            guard enabled, request.version == 1, let inventory,
                  let device = inventory.peers.first(where: { $0.address == address && $0.online }) else { throw TailnetError.denied }
            if request.operation == .hello { return TailnetResponse(status: "hello", device: inventory.local) }
            if request.operation == .pair {
                guard let id = request.pairingID, let token = request.token, Data(base64Encoded: token)?.count == 32,
                      !(try store.peers()).contains(where: { $0.id == device.id }),
                      pending[id] == nil, pending.count < 8, requestedAt[device.id, default: .distantPast] < now().addingTimeInterval(-60) else { throw TailnetError.denied }
                requestedAt[device.id] = now()
                pending[id] = (TailnetPairingRequest(id: id, device: device, expires: now().addingTimeInterval(120)), token)
                return TailnetResponse(status: "pending")
            }
            if request.operation == .pairingStatus, let id = request.pairingID, let value = pending[id],
               value.request.device.id == device.id, value.request.expires > now(), TailnetKeychain.matches(value.token, request.token) {
                return TailnetResponse(status: "pending")
            }
            let peer = try authorised(request, device: device)
            if request.operation == .pairingStatus { return TailnetResponse(status: "approved") }
            if request.operation == .revoke {
                try store.remove(peer.id); try credentials.remove(peer.pairingID)
                if preparation?.peerID == peer.id { preparation?.task.cancel() }
                for (id, transfer) in incoming where transfer.peer == peer.id { finalising[id]?.cancel() }
                incoming = incoming.filter { $0.value.peer != peer.id }
                return TailnetResponse(status: "ok")
            }
            guard let id = request.entryID else { throw TailnetError.invalid("Missing entry identity.") }
            if request.operation == .received { return TailnetResponse(status: try store.hasReceived(id) ? "seen" : "new") }
            if request.operation == .begin {
                guard finalising[id] == nil else { throw TailnetError.unavailable("Transfer is being committed; retry shortly.") }
                guard let manifest = request.manifest, manifest.entry.id == id else { throw TailnetError.invalid("Missing manifest.") }
                if try store.hasReceived(id) { return TailnetResponse(status: "seen") }
                guard incoming[id] == nil || incoming[id]?.peer == peer.id,
                      incoming.count < 8 || incoming[id] != nil else { throw TailnetError.unavailable("Receiver is busy; retry shortly.") }
                // One active selection per peer bounds aggregate disk exposure.
                for (other, transfer) in incoming where transfer.peer == peer.id && other != id {
                    try files.discardPartial(other); incoming.removeValue(forKey: other)
                }
                let offsets = try files.begin(manifest, limit: peer.receiveLimitBytes)
                incoming[id] = (peer.id, peer.pairingID, manifest)
                return TailnetResponse(status: "ready", offsets: offsets)
            }
            guard let transfer = incoming[id], transfer.peer == peer.id, transfer.pairing == peer.pairingID else { throw TailnetError.denied }
            if request.operation == .chunk {
                guard finalising[id] == nil else { throw TailnetError.denied }
                guard let bytes = request.bytes, let index = request.index, let offset = request.offset else { throw TailnetError.invalid("Missing chunk.") }
                try files.appendChunk(bytes, index: index, offset: offset, manifest: transfer.manifest)
                return TailnetResponse(status: "ok")
            }
            if request.operation == .commit {
                try transfer.manifest.validate(limit: peer.receiveLimitBytes)
                guard finalising[id] == nil else { throw TailnetError.unavailable("Transfer is being committed; retry shortly.") }
                let files = files
                let run = generation
                let task = Task.detached(priority: .utility) { try files.finish(transfer.manifest) }
                finalising[id] = task
                defer { finalising.removeValue(forKey: id) }
                let entry = try await task.value
                guard enabled, generation == run, incoming[id]?.pairing == peer.pairingID else { throw TailnetError.denied }
                let currentPeer = try authorised(request, device: device)
                try transfer.manifest.validate(limit: currentPeer.receiveLimitBytes)
                let inserted = try store.receive(entry, publishToCloud: currentPeer.publishToCloud)
                incoming.removeValue(forKey: id)
                files.acknowledge(id)
                if inserted { await onReceived(entry, currentPeer.replaceClipboard && !transfer.manifest.backfill) }
                return TailnetResponse(status: "ok")
            }
            throw TailnetError.invalid("Unsupported request.")
        } catch { return TailnetResponse(status: "denied", message: (error as? TailnetError)?.localizedDescription ?? "Storage could not complete the transfer.") }
    }

    private func transmit(_ transfer: TailnetTransfer, to initialPeer: TailnetPeer) async throws {
        guard let entry = try store.database.fetch(id: transfer.id) else { return }
        var query = TailnetRequest(operation: .received); query.entryID = entry.id
        if try await call(query, peer: initialPeer).status == "seen" { try store.setState(transfer, .sent); return }
        let files = files
        let task = Task.detached(priority: .utility) { try files.prepare(entry, backfill: transfer.backfill) }
        preparation = (initialPeer.id, task)
        defer { preparation = nil }
        let prepared = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { prepared.cleanup() }
        guard enabled, let currentPeer = try store.peers().first(where: { $0.id == initialPeer.id }), currentPeer.pairingID == initialPeer.pairingID else { throw CancellationError() }
        let digest = try prepared.manifest.digest
        if entry.contentType == .filePath, prepared.manifest.totalBytes > currentPeer.approvalBytes, transfer.approvedDigest != digest {
            try store.setState(transfer, .approval, detail: "\(prepared.manifest.totalBytes) bytes\(prepared.manifest.changedSinceCapture ? " · changed since capture" : "")", digest: digest)
            return
        }
        query.operation = .begin; query.manifest = prepared.manifest
        let begin = try await call(query, peer: initialPeer)
        if begin.status == "seen" { try store.setState(transfer, .sent); return }
        guard begin.status == "ready", let offsets = begin.offsets, offsets.count == prepared.sources.count else { throw TailnetError.invalid("Receiver rejected the transfer manifest.") }
        for (index, source) in prepared.sources.enumerated() {
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            var offset = offsets[index]
            let size = prepared.manifest.files[index].size
            guard offset >= 0, offset <= size else { throw TailnetError.invalid("Receiver requested an invalid offset.") }
            try handle.seek(toOffset: UInt64(offset))
            while offset < size {
                try Task.checkCancellation()
                guard let bytes = try handle.read(upToCount: Int(min(Int64(TailnetFiles.chunkSize), size - offset))), !bytes.isEmpty else { throw TailnetError.invalid("Source file changed during transfer. Retry to send its current contents.") }
                var chunk = TailnetRequest(operation: .chunk); chunk.entryID = entry.id; chunk.index = index; chunk.offset = offset; chunk.bytes = bytes
                _ = try await call(chunk, peer: initialPeer)
                offset += Int64(bytes.count)
                if offset == size || offset % 1_048_576 == 0 {
                    try store.setState(transfer, .pending, detail: "Sending file \(index + 1) of \(prepared.sources.count) · \(offset) / \(size) bytes")
                }
            }
        }
        var commit = TailnetRequest(operation: .commit); commit.entryID = entry.id
        _ = try await call(commit, peer: initialPeer)
        try store.setState(transfer, .sent, detail: prepared.manifest.changedSinceCapture ? "Sent current contents · changed since capture" : "Delivered")
    }
    private func call(_ original: TailnetRequest, peer: TailnetPeer) async throws -> TailnetResponse {
        guard enabled, let inventory, let current = try store.peers().first(where: { $0.id == peer.id }),
              current.pairingID == peer.pairingID, current.localNodeID == inventory.local.id, current.sendEnabled,
              let device = inventory.peers.first(where: { $0.id == peer.id && $0.online }) else { throw CancellationError() }
        if !current.forwardReceived, let id = original.entryID, try store.database.fetch(id: id)?.receivedViaTailnet == true { throw CancellationError() }
        var request = original; request.pairingID = peer.pairingID; request.token = try credentials.read(peer.pairingID)
        let response = try await send(request, device.address, inventory.local.address)
        if response.status == "denied" { throw TailnetError.unavailable(response.message ?? "Pairing was removed on the other Mac. Remove it here and pair again.") }
        return response
    }
}
#endif
