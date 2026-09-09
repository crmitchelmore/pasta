import PastaCore
import PastaSync
import SwiftUI

struct TailnetSettingsTab: View {
    @ObservedObject var sync: TailnetSyncController
    var body: some View {
        Form {
            Section {
                Toggle("Enable Tailnet Sync", isOn: Binding(get: { sync.enabled }, set: sync.setEnabled))
                Text(sync.status).foregroundStyle(.secondary)
                Text("Pair your own Macs across iCloud accounts using Tailscale. Each Mac keeps its own history. Pairing requests appear on the target Mac for approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sync.enabled {
                Section("Add a Mac") {
                    let unpaired = sync.devices.filter { device in !sync.peers.contains(where: { $0.id == device.id }) }
                    if unpaired.isEmpty {
                        Text("No unpaired Macs found. Enable Tailnet Sync in Pasta on the other Mac and check Tailscale allows connections.").foregroundStyle(.secondary)
                    }
                    ForEach(unpaired) { device in
                        HStack { Text(device.name); Spacer(); Button("Request pairing") { sync.pair(device.id) } }
                    }
                }
            }
            ForEach(sync.peers) { peer in
                Section(peer.name) { TailnetPeerSettings(peer: peer, sync: sync) }
            }
            let outstanding = sync.transfers.filter { $0.state != .sent }
            if !outstanding.isEmpty {
                Section("Transfers") {
                    ForEach(outstanding, id: \.transferKey) { transfer in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transfer.title).lineLimit(2)
                            Text("To \(sync.peers.first(where: { $0.id == transfer.peerID })?.name ?? "paired Mac")")
                            Text(transfer.detail ?? transfer.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if transfer.state == .approval {
                                    Button("Approve transfer") { sync.approveTransfer(transfer) }
                                    Button("Decline") { sync.declineTransfer(transfer) }
                                } else if transfer.state == .failed {
                                    Button("Retry") { sync.retry(transfer) }
                                }
                            }
                        }
                    }
                }
            }
            let recent = Array(sync.transfers.filter { $0.state == .sent }.prefix(10))
            if !recent.isEmpty {
                Section("Recently sent") {
                    ForEach(recent, id: \.transferKey) { transfer in
                        VStack(alignment: .leading) {
                            Text(transfer.title).lineLimit(1)
                            Text(transfer.detail ?? "Delivered").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Files and history") {
                Text("Received files are held by Pasta and removed when their history entry is deleted or expires. Save a copy elsewhere to keep it. Originals are never deleted. Files stay on the tailnet and are not uploaded to iCloud.")
                Text("Offline Macs catch up with retained history when both are running again. Missing original files cannot be transferred. Later edits and deletions stay within each account.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .alert("Tailnet Sync", isPresented: Binding(get: { sync.error != nil }, set: { if !$0 { sync.error = nil } })) {
            Button("OK") { sync.error = nil }
        } message: { Text(sync.error ?? "") }
    }
}
private extension TailnetTransfer {
    var transferKey: String { peerID + id.uuidString }
}
private struct TailnetPeerSettings: View {
    let peer: TailnetPeer
    @ObservedObject var sync: TailnetSyncController
    @State private var confirmHistory = false
    @State private var confirmRemove = false
    var body: some View {
        Group {
            Text(sync.devices.contains(where: { $0.id == peer.id }) ? "Available" : "Offline or Pasta unavailable")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Send new items to this Mac", isOn: binding(\.sendEnabled))
            Toggle("Forward items received from other devices", isOn: binding(\.forwardReceived))
            Toggle("Publish received items to my iCloud history", isOn: binding(\.publishToCloud))
            Text("Applies to items received from now on; also requires iCloud sync to be enabled.").font(.caption).foregroundStyle(.secondary)
            Toggle("Replace my clipboard with received items", isOn: binding(\.replaceClipboard))
            Text("Does not paste into an app. Older-history imports never replace the clipboard.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Ask before sending above (MB)")
                TextField("50", value: megabytes(\.approvalBytes), format: .number).frame(width: 95)
            }
            HStack {
                Text("Maximum received selection (MB)")
                TextField("1000", value: megabytes(\.receiveLimitBytes), format: .number).frame(width: 95)
            }
            HStack {
                Button("Send older history…") { confirmHistory = true }.disabled(!peer.sendEnabled)
                Spacer()
                Button("Remove pairing…", role: .destructive) { confirmRemove = true }
            }
        }
        .confirmationDialog("Send retained older history to \(peer.name)?", isPresented: $confirmHistory) {
            Button("Send history") { sync.sendHistory(peer.id) }
        } message: { Text("Includes all retained items allowed by forwarding settings. Large file transfers still require approval.") }
        .confirmationDialog("Remove pairing with \(peer.name)?", isPresented: $confirmRemove) {
            Button("Remove pairing", role: .destructive) { sync.remove(peer.id) }
        } message: { Text("Transfers stop. Received history and files remain until normal deletion or expiry.") }
    }
    private func binding(_ key: WritableKeyPath<TailnetPeer, Bool>) -> Binding<Bool> {
        Binding(get: { current[keyPath: key] }, set: { value in var updated = current; updated[keyPath: key] = value; sync.save(updated) })
    }
    private func megabytes(_ key: WritableKeyPath<TailnetPeer, Int64>) -> Binding<Int64> {
        Binding(get: { current[keyPath: key] / 1_000_000 }, set: { value in
            guard (1...1_000_000).contains(value) else { return }
            var updated = current; updated[keyPath: key] = value * 1_000_000; sync.save(updated)
        })
    }
    private var current: TailnetPeer { sync.peers.first(where: { $0.id == peer.id }) ?? peer }
}
