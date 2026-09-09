#if os(macOS)
import Foundation

public struct TailnetDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var online: Bool
    public init(id: String, name: String, address: String, online: Bool = true) {
        self.id = id; self.name = name; self.address = address; self.online = online
    }
}
struct TailnetInventory: Sendable {
    var local: TailnetDevice
    var peers: [TailnetDevice]
    static func parse(_ data: Data) throws -> Self {
        struct Node: Decodable {
            var ID: String; var HostName: String; var TailscaleIPs: [String]?; var Online: Bool?; var OS: String?
        }
        struct Status: Decodable { var BackendState: String; var SelfNode: Node; var Peer: [String: Node]?
            enum CodingKeys: String, CodingKey { case BackendState, SelfNode = "Self", Peer }
        }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.BackendState == "Running" else { throw TailnetError.unavailable("Connect Tailscale to discover your Macs.") }
        func device(_ node: Node) -> TailnetDevice? {
            guard let address = node.TailscaleIPs?.first(where: TailnetInventory.isTailnetIPv4) else { return nil }
            return TailnetDevice(id: node.ID, name: String(node.HostName.prefix(100)), address: address, online: node.Online ?? false)
        }
        guard let local = device(status.SelfNode) else { throw TailnetError.unavailable("Tailscale has no IPv4 address on this Mac.") }
        return Self(local: local, peers: (status.Peer ?? [:]).values.filter { $0.OS?.lowercased() == "macos" }.compactMap(device).sorted { $0.name < $1.name })
    }
    static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "100" && (64...127).contains(Int(parts[1]) ?? -1)
    }
}

enum TailnetDiscovery {
    static func inventory() async throws -> TailnetInventory {
        try await Task.detached(priority: .utility) {
            let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw TailnetError.unavailable("Install and connect Tailscale to use Tailnet Sync.")
            }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("pasta-tailnet-status-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            defer { try? FileManager.default.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            // Finder-launched apps have no terminal environment. The macOS
            // Tailscale executable otherwise selects GUI mode and emits non-JSON.
            var environment = ProcessInfo.processInfo.environment
            environment["TAILSCALE_BE_CLI"] = "1"
            process.environment = environment
            process.arguments = ["status", "--json"]
            process.standardOutput = handle; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { process.terminate(); throw TailnetError.timeout }
            guard process.terminationStatus == 0 else { throw TailnetError.unavailable("Tailscale status is unavailable. Check that Tailscale is connected.") }
            let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4_000_000 else { throw TailnetError.invalid("Tailnet inventory exceeds the supported size.") }
            return try TailnetInventory.parse(Data(contentsOf: output))
        }.value
    }
}
#endif
