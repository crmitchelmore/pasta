#if os(macOS)
import Foundation
import Network

struct TailnetRequest: Codable, Sendable {
    enum Operation: String, Codable { case hello, pair, pairingStatus, received, begin, chunk, commit, revoke }
    var version = 1
    var operation: Operation
    var pairingID: UUID?
    var token: String?
    var entryID: UUID?
    var manifest: TailnetManifest?
    var index: Int?
    var offset: Int64?
    var bytes: Data?
}
struct TailnetResponse: Codable, Sendable {
    var version = 1
    var status: String
    var device: TailnetDevice?
    var token: String?
    var offsets: [Int64]?
    var message: String?
}

/// One bounded request per connection. Tailnet encryption is provided by
/// Tailscale; application tokens bind the request to an explicitly approved node.
final class TailnetTransport: @unchecked Sendable {
    static let port: UInt16 = 45873
    static let maximumFrame = 3_000_000
    private let queue = DispatchQueue(label: "com.pasta.tailnet.network", qos: .utility)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    typealias Handler = @Sendable (String, TailnetRequest) async -> TailnetResponse

    @discardableResult
    func listen(address: String, port: UInt16 = port, handler: @escaping Handler) async throws -> UInt16 {
        guard TailnetInventory.isTailnetIPv4(address) || address == "127.0.0.1" else { throw TailnetError.denied }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID(); self.connections[id] = connection
            let host: String
            if case .hostPort(let endpointHost, _) = connection.endpoint { host = String(describing: endpointHost) }
            else { connection.cancel(); self.connections.removeValue(forKey: id); return }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 20) { [weak self, weak connection] in
                connection?.cancel(); self?.connections.removeValue(forKey: id)
            }
            Task {
                do {
                    let data = try await Self.readFrame(connection)
                    let request = try JSONDecoder().decode(TailnetRequest.self, from: data)
                    let response = await handler(host, request)
                    try await Self.writeFrame(try JSONEncoder().encode(response), to: connection)
                } catch { /* Never log clipboard payloads, tokens or remote error bodies. */ }
                connection.cancel()
                self.queue.async { self.connections.removeValue(forKey: id) }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = TailnetListenerCompletion(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let port = listener?.port { completion.finish(.success(port.rawValue)) }
                    else { completion.finish(.failure(TailnetError.unavailable("Could not bind the tailnet listener."))) }
                case .failed(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(CancellationError()))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 5) {
                if completion.finish(.failure(TailnetError.timeout)) { listener.cancel() }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }
    static func request(_ request: TailnetRequest, address: String, localAddress: String? = nil, port: UInt16 = port) async throws -> TailnetResponse {
        guard TailnetInventory.isTailnetIPv4(address) || address == "127.0.0.1" else { throw TailnetError.denied }
        let parameters = NWParameters.tcp
        if let localAddress {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localAddress), port: .any)
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let queue = DispatchQueue(label: "com.pasta.tailnet.request", qos: .utility)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + (request.operation == .hello ? 2 : 15)) { connection.cancel() }
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await writeFrame(JSONEncoder().encode(request), to: connection)
            let result = try JSONDecoder().decode(TailnetResponse.self, from: await readFrame(connection))
            guard result.version == 1 else { throw TailnetError.invalid("Update Pasta on both Macs to compatible versions.") }
            return result
        } onCancel: { connection.cancel() }
    }
    private static func read(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: TailnetError.invalid("Incomplete transfer message.")) }
            }
        }
    }
    static func readFrame(_ connection: NWConnection) async throws -> Data {
        let header = try await read(4, from: connection)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumFrame else { throw TailnetError.invalid("Transfer message exceeds the size limit.") }
        return try await read(length, from: connection)
    }
    static func writeFrame(_ data: Data, to connection: NWConnection) async throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw TailnetError.invalid("Transfer message exceeds the size limit.") }
        let n = UInt32(data.count)
        var frame = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
private final class TailnetListenerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<UInt16, Error>) -> Bool {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
        return value != nil
    }
}
#endif
