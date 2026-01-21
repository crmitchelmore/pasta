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
    @State private var hasAccessibility: Bool = AccessibilityPermission.isTrusted()
    @State private var hasInputMonitoring: Bool = AccessibilityPermission.hasInputMonitoring()
    @State private var pollTimer: Timer? = nil

    private let onComplete: (Completion) -> Void
    
    private var hasAllPermissions: Bool {
        hasAccessibility && hasInputMonitoring
    }

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
            Text("Grant Permissions")
                .font(.headline)

            Text("Pasta needs two permissions for global hotkeys to work:")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                // Accessibility permission
                HStack(spacing: 8) {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(hasAccessibility ? .green : .orange)
                    Text("Accessibility")
                        .fontWeight(.medium)
                    Text("(for pasting)")
                        .foregroundStyle(.secondary)
                }
                
                // Input Monitoring permission
                HStack(spacing: 8) {
                    Image(systemName: hasInputMonitoring ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(hasInputMonitoring ? .green : .orange)
                    Text("Input Monitoring")
                        .fontWeight(.medium)
                    Text("(for global hotkey)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("Open Accessibility Settings") {
                        openAccessibilitySettings()
                    }
                    .disabled(hasAccessibility)

                    Button("Open Input Monitoring") {
                        openInputMonitoringSettings()
                    }
                    .disabled(hasInputMonitoring)
                }
                
                HStack(spacing: 12) {
                    Button("Request Permissions") {
                        AccessibilityPermission.requestPrompt()
                        AccessibilityPermission.requestInputMonitoring()
                        refreshTrust()
                    }
                    
                    Button("Refresh Status") {
                        refreshTrust()
                    }
                }
            }

            if hasAllPermissions {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All permissions granted!")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                Text("Note: You may need to restart Pasta after granting permissions for them to take effect.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
        hasAccessibility = AccessibilityPermission.isTrusted()
        hasInputMonitoring = AccessibilityPermission.hasInputMonitoring()
        if hasAllPermissions {
            step = .done
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // Poll more frequently (every 0.5s) for better responsiveness
        // Timer is stored in @State and invalidated in onDisappear
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                refreshTrust()
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
    
    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
