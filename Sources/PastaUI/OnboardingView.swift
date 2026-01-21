import AppKit
import PastaCore
import SwiftUI

public struct OnboardingView: View {
    public enum Completion {
        case dismissed
        case completed
    }

    private enum Step: Int {
        case welcome
        case accessibility
        case done
    }

    @State private var step: Step = .welcome
    @State private var isTrusted: Bool = AccessibilityPermission.isTrusted()
    @State private var pollTimer: Timer? = nil

    private let onComplete: (Completion) -> Void

    public init(onComplete: @escaping (Completion) -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                switch step {
                case .welcome:
                    welcome
                case .accessibility:
                    accessibility
                case .done:
                    done
                }
            }

            Spacer()

            footer
        }
        .padding(20)
        .frame(width: 520, height: 340)
        .onAppear {
            refreshTrust()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private var header: some View {
        HStack {
            Text("Welcome to Pasta")
                .font(.title2.bold())
            Spacer()
            Button("Skip") {
                step = .done
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pasta keeps a searchable history of what you copy.")
            Text("To enable quick paste, Pasta needs Accessibility permission to simulate ⌘V.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue") {
                    step = .accessibility
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grant Accessibility permission")
                .font(.headline)

            Text("Open System Settings → Privacy & Security → Accessibility, then enable Pasta.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("Open Accessibility Settings") {
                        openAccessibilitySettings()
                    }

                    Button("Show Permission Prompt") {
                        AccessibilityPermission.requestPrompt()
                    }
                    .help("Shows the system prompt (if available).")
                }
                
                Button("Refresh Permission Status") {
                    refreshTrust()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: isTrusted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(isTrusted ? .green : .secondary)

                Text(isTrusted ? "Accessibility permission granted." : "Not granted yet. Pasta can still capture history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text("Note: Permission detection can sometimes be delayed. If you've granted permission but it's not detected, try clicking Refresh or restarting the app.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're all set")
                .font(.headline)

            Text("Use ⌃⌘C to open Pasta, search your clipboard history, and press ↩︎ to paste.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Finish") {
                    onComplete(.completed)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Step \(step.rawValue + 1) of 3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func refreshTrust() {
        // AXIsProcessTrusted() can be cached - try multiple times
        let trusted = AccessibilityPermission.isTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            if trusted {
                step = .done
            }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // Poll more frequently (every 0.5s) for better responsiveness
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [self] in
                self.refreshTrust()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
