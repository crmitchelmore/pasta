#if os(macOS)
import AppKit
import Combine
import Foundation
import PastaCore

@MainActor
public final class TailnetSyncController: ObservableObject {
    @Published public private(set) var enabled: Bool
    @Published public private(set) var status = "Off"
    @Published public private(set) var devices: [TailnetDevice] = []
    @Published public private(set) var peers: [TailnetPeer] = []
    @Published public private(set) var requests: [TailnetPairingRequest] = []
    @Published public private(set) var transfers: [TailnetTransfer] = []
    @Published public var error: String?
    private let engine: TailnetEngine
    private let defaults: UserDefaults
    private var monitor: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var displayedRequests: Set<UUID> = []
    private var showingRequest = false

    public init(database: DatabaseManager, root: URL? = nil, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "pasta.tailnet.enabled")
        let root = root ?? DatabaseManager.defaultDatabaseURL().deletingLastPathComponent().appendingPathComponent("Tailnet Files", isDirectory: true)
        engine = try TailnetEngine(database: database, root: root) { entry, replaceClipboard in
            await MainActor.run {
                if replaceClipboard {
                    if PasteService().copy(entry) {
                        // Capture ignores this marker independently of the user's
                        // transient-content preference. Never simulate Command-V.
                        NSPasteboard.general.setString("1", forType: NSPasteboard.PasteboardType("com.pasta.tailnet-received"))
                    }
                }
                NotificationCenter.default.post(name: Notification.Name("pasta.entriesDidChange"), object: nil)
            }
        }
    }
    public func start() {
        guard monitor == nil else { return }
        let engine = engine
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await engine.setEnabled(self.enabled)
                await engine.tick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                if let snapshot = try? await engine.snapshot(), let self {
                    self.status = snapshot.status; self.devices = snapshot.devices
                    self.peers = snapshot.peers; self.requests = snapshot.requests
                    self.transfers = snapshot.transfers
                    self.presentNextRequest()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    public func stop() {
        monitor?.cancel(); worker?.cancel(); monitor = nil; worker = nil
        Task { await engine.setEnabled(false) }
    }
    public func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "pasta.tailnet.enabled")
        Task { await engine.setEnabled(value) }
    }
    private func perform(_ action: @escaping @Sendable (TailnetEngine) async throws -> Void) {
        Task {
            do { try await action(engine) }
            catch { self.error = (error as? TailnetError)?.localizedDescription ?? "Pasta could not update tailnet sync. Check storage and Tailscale, then retry." }
        }
    }
    public func pair(_ id: String) { perform { try await $0.requestPairing(id) } }
    public func save(_ peer: TailnetPeer) {
        if let index = peers.firstIndex(where: { $0.id == peer.id }) { peers[index] = peer }
        perform { try await $0.update(peer) }
    }
    public func sendHistory(_ id: String) { perform { try await $0.backfill(id) } }
    public func remove(_ id: String) { perform { try await $0.unpair(id) } }
    public func approveTransfer(_ transfer: TailnetTransfer) { perform { try await $0.decideTransfer(transfer, approve: true) } }
    public func declineTransfer(_ transfer: TailnetTransfer) { perform { try await $0.decideTransfer(transfer, approve: false) } }
    public func retry(_ transfer: TailnetTransfer) { perform { try await $0.retry(transfer) } }
    public func decidePairing(_ id: UUID, allow: Bool) { perform { try await $0.approve(id, allow: allow) } }

    private func presentNextRequest() {
        guard !showingRequest, let request = requests.first(where: { !displayedRequests.contains($0.id) }) else { return }
        displayedRequests.insert(request.id); showingRequest = true
        let alert = NSAlert()
        alert.messageText = "Allow \(request.device.name) to sync with this Mac?"
        alert.informativeText = "This device is on your tailnet. Pairing shares new Pasta history both ways, including anything your capture settings allow. Older history, onward iCloud sharing and clipboard replacement stay off until you enable them."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Decline")
        // A non-modal window keeps Pasta usable while a request is pending.
        // The sheet is attached to a dedicated window so Settings need not be open.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Pasta Pairing"; window.center(); window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            window.close()
            self?.showingRequest = false
            self?.decidePairing(request.id, allow: response == .alertFirstButtonReturn)
        }
        Task { [weak window, weak alert] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if let window, let alert, window.attachedSheet === alert.window { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
        }
    }
}
#endif
