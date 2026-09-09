import AppKit
import PastaCore
import SwiftUI

/// One nonactivating guide, shared by every explicit permission entry point.
@MainActor
public final class MacPermissionGuidance: NSObject, NSWindowDelegate {
    public static let shared = MacPermissionGuidance()
    private var panel: NSPanel?
    private var model: PermissionGuidanceModel?

    public func show(_ permission: MacPermission) {
        close()
        let model = PermissionGuidanceModel(permission: permission, store: .shared,
                                            identity: .current, open: { NSWorkspace.shared.open($0) })
        self.model = model
        let panel = PermissionGuidePanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 480),
                                        styleMask: [.titled, .closable, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        panel.title = "\(model.identity.name) — \(permission.title)"
        panel.isReleasedWhenClosed = false
        // Keyboard users can return to the guide through the standard Window menu.
        panel.isExcludedFromWindowsMenu = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PermissionGuideView(model: model, store: model.store) { [weak self] in self?.close() })
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 20,
                                         y: max(area.minY, area.midY - panel.frame.height / 2)))
        }
        self.panel = panel
        NSApp.addWindowsItem(panel, title: panel.title, filename: false)
        panel.orderFrontRegardless()
        model.openSettings()
    }

    public func close() {
        model?.stopChecking()
        if let panel { NSApp.removeWindowsItem(panel) }
        panel?.delegate = nil
        panel?.close()
        panel = nil
        model = nil
    }

    public func windowWillClose(_ notification: Notification) { close() }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuidanceModel
    @ObservedObject var store: MacPermissionStore
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var granted: Bool { store.snapshot.allows(model.permission) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(granted ? "Access available" : "Allow \(model.permission.title)",
                      systemImage: granted ? "checkmark.circle.fill" : "hand.raised")
                    .font(.title2.weight(.semibold))
                Text(model.permission == .accessibility
                     ? "\(model.identity.name) uses this to paste into other apps. You can still copy clips and paste them yourself."
                     : "\(model.identity.name) uses this for automatic snippet expansion while you type. The standard shortcut does not need it.")
                if !granted {
                    Text("In System Settings → Privacy & Security → \(model.permission.title), turn on \(model.identity.name).")
                    if model.identity.isAppBundle {
                        Text("If it is missing, drag this app card into the list, or use the + button to choose the app at the path below. Then turn on its switch.")
                        dragCard
                    } else {
                        Text("Launch a bundled copy of the app to add it to System Settings.")
                    }
                }
                Text(model.identity.bundleURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Copy App Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.identity.bundleURL.path, forType: .string)
                }
                Text("Other builds and copies can have separate permissions. Check that the enabled app is this copy.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If macOS asks you to quit and reopen the app, follow that instruction.")
                    .font(.caption).foregroundStyle(.secondary)

            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.feedback.isEmpty {
                    Text(model.feedback).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Open Settings") { model.openSettings() }
                    Button("Check Again") { model.checkAgain() }
                        .keyboardShortcut(.return, modifiers: [])
                    Spacer()
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .frame(width: 390, height: 480)
        .onChange(of: store.snapshot) { _, _ in
            // Feedback from an earlier check must not contradict live OS state.
            if !model.feedback.isEmpty { model.checkAgain() }
        }
        .onDisappear { model.stopChecking() }
    }

    private var dragCard: some View {
        HStack(spacing: 16) {
            Label(model.identity.name, systemImage: "app.fill")
                .font(.headline)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .onDrag { NSItemProvider(contentsOf: model.identity.bundleURL) ?? NSItemProvider() }
                .accessibilityLabel("\(model.identity.name) app. Drag into the \(model.permission.title) list in System Settings.")
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                Image(systemName: "arrow.right")
                    .offset(x: reduceMotion ? 0 : 4 * sin(context.date.timeIntervalSinceReferenceDate * 3))
            }
            .accessibilityHidden(true)
            Image(systemName: "gearshape.fill").accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}

/// Inline setup is also usable with keyboard/VoiceOver, without dragging.
public struct MacPermissionSetupRow: View {
    let permission: MacPermission
    @ObservedObject private var store = MacPermissionStore.shared
    @State private var session: UUID?

    public init(_ permission: MacPermission) { self.permission = permission }

    public var body: some View {
        HStack {
            Label(permission.title, systemImage: store.snapshot.allows(permission) ? "checkmark.circle.fill" : "hand.raised")
            Spacer()
            Text(store.snapshot.allows(permission) ? "Available" : "Not enabled")
                .foregroundStyle(.secondary)
            Button("Set Up…") { MacPermissionGuidance.shared.show(permission) }
        }
        .onAppear { session = store.beginSession(for: permission) }
        .onDisappear { if let session { store.endSession(session) }; session = nil }
    }
}
