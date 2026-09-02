import AppKit
import PastaCore
import SwiftUI

// MARK: - Onboarding View

public struct OnboardingView: View {
    public enum Completion {
        case dismissed
        case completed
    }

    private enum Step: Int, CaseIterable {
        case welcome = 0
        case features
        case permissions
        case ready
    }

    @State private var step: Step = .welcome
    @State private var featureTipIndex: Int = 0
    @State private var hasAccessibility: Bool = AccessibilityPermission.isTrusted()
    @State private var hasInputMonitoring: Bool = AccessibilityPermission.hasInputMonitoring()
    @State private var pollTimer: Timer? = nil
    @State private var appearAnimation: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onComplete: (Completion) -> Void
    
    /// Accessibility is the only permission pasting depends on; Input
    /// Monitoring is surfaced as optional and never gates progress.
    private var hasRequiredPermissions: Bool {
        hasAccessibility
    }
    
    private let featureTips: [FeatureTip] = [
        FeatureTip(
            icon: "exclamationmark.bubble",
            title: "Command Mode",
            description: "Type ! in Quick Search to run commands like clear history ranges, pause capture, and open settings.",
            accent: Color(red: 1.0, green: 0.45, blue: 0.35)
        ),
        FeatureTip(
            icon: "rectangle.and.text.magnifyingglass",
            title: "Preview + Quick Actions",
            description: "In Quick Search, press → to open the preview, Return to paste, and ⌘⌫ to delete — all without leaving the keyboard.",
            accent: Color(red: 0.35, green: 0.65, blue: 0.95)
        ),
        FeatureTip(
            icon: "line.3.horizontal.decrease.circle",
            title: "Search + Filters",
            description: "Search by text, then narrow results with sidebar filters for type, app, and URL domain.",
            accent: Color(red: 0.55, green: 0.78, blue: 0.25)
        ),
        FeatureTip(
            icon: "keyboard",
            title: "Quick Paste",
            description: "Press ⌃⌘V, select a clip, and hit Return. Use ⌘1-⌘9 for instant slot pasting.",
            accent: Color(red: 0.75, green: 0.45, blue: 0.95)
        ),
        FeatureTip(
            icon: "tag",
            title: "Smart Detection",
            description: "URLs, emails, code, API keys, and more are auto-detected so filters and previews stay useful.",
            accent: Color(red: 0.94, green: 0.74, blue: 0.18)
        ),
        FeatureTip(
            icon: "iphone.and.arrow.right.inward",
            title: "Continuity Sync",
            description: "Copies from your iPhone can appear automatically via Handoff and iCloud sync.",
            accent: Color(red: 0.64, green: 0.56, blue: 0.94)
        )
    ]

    public init(onComplete: @escaping (Completion) -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            // Animated gradient background
            backgroundGradient
            
            VStack(spacing: 0) {
                // Progress indicator
                progressBar
                    .padding(.top, 20)
                    .padding(.horizontal, 32)
                
                // Main content
                Group {
                    switch step {
                    case .welcome:
                        welcomeStep
                    case .features:
                        featuresStep
                    case .permissions:
                        permissionsStep
                    case .ready:
                        readyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Navigation footer
                navigationFooter
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 540, height: 450)
        .clipShape(RoundedRectangle(cornerRadius: PastaTheme.Radius.xl, style: .continuous))
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appearAnimation = true
            }
            refreshTrust()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }
    
    // MARK: - Background
    
    private var backgroundGradient: some View {
        ZStack {
            // Base gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Accent glow based on current step
            RadialGradient(
                colors: [
                    currentAccentColor.opacity(0.15),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 300
            )
            .blur(radius: 40)
            .offset(x: 50, y: -50)
            
            // Subtle pattern overlay
            GeometryReader { geo in
                Canvas { context, size in
                    for i in stride(from: 0, to: size.width, by: 40) {
                        for j in stride(from: 0, to: size.height, by: 40) {
                            let rect = CGRect(x: i, y: j, width: 1, height: 1)
                            context.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(0.02)))
                        }
                    }
                }
            }
        }
    }
    
    private var currentAccentColor: Color {
        switch step {
        case .welcome: return PastaTheme.accent
        case .features: return featureTips[featureTipIndex].accent
        case .permissions: return Color.orange
        case .ready: return PastaTheme.success
        }
    }
    
    // MARK: - Progress Bar
    
    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? currentAccentColor : Color.primary.opacity(0.1))
                    .frame(height: 3)
                    .animation(.spring(response: 0.4), value: step)
            }
        }
    }
    
    // MARK: - Welcome Step
    
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // App icon / logo area
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [PastaTheme.accent.opacity(0.3), PastaTheme.accent.opacity(0.05)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(PastaTheme.accent)
                    .symbolEffect(.bounce, value: appearAnimation)
            }
            .scaleEffect(appearAnimation ? 1 : 0.8)
            .opacity(appearAnimation ? 1 : 0)
            
            VStack(spacing: 12) {
                Text("Welcome to Pasta")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text("Your clipboard, supercharged")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(appearAnimation ? 1 : 0)
            .offset(y: appearAnimation ? 0 : 10)
            
            Spacer()
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Features Step
    
    private var featuresStep: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Feature card
            featureCard(tip: featureTips[featureTipIndex])
                .id(featureTipIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            
            // Tip navigation dots
            HStack(spacing: 8) {
                ForEach(0..<featureTips.count, id: \.self) { index in
                    Circle()
                        .fill(index == featureTipIndex ? featureTips[featureTipIndex].accent : Color.primary.opacity(0.15))
                        .frame(width: index == featureTipIndex ? 8 : 6, height: index == featureTipIndex ? 8 : 6)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35)) {
                                featureTipIndex = index
                            }
                        }
                }
            }
            .padding(.top, 8)
            
            Spacer()
        }
        .padding(.horizontal, 40)
    }
    
    private func featureCard(tip: FeatureTip) -> some View {
        VStack(spacing: 20) {
            // Icon with glow
            ZStack {
                Circle()
                    .fill(tip.accent.opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Image(systemName: tip.icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(tip.accent)
                    // One pulse as the card appears; nothing when Reduce Motion is on.
                    .symbolEffect(.pulse.byLayer, options: .nonRepeating, isActive: !reduceMotion)
            }
            
            VStack(spacing: 8) {
                Text(tip.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(tip.description)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 320)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .background {
            RoundedRectangle(cornerRadius: PastaTheme.Radius.xl, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: PastaTheme.Radius.xl, style: .continuous)
                        .stroke(tip.accent.opacity(0.2), lineWidth: 1)
                }
        }
    }
    
    // MARK: - Permissions Step
    
    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("Quick Setup")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                
                Text("Accessibility is required to paste. Input Monitoring is optional.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 12) {
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Paste into any app",
                    granted: hasAccessibility,
                    action: { 
                        AccessibilityPermission.requestPrompt()
                        AccessibilityPermission.openAccessibilitySettings()
                    }
                )
                
                permissionRow(
                    title: "Input Monitoring",
                    subtitle: "Optional — not needed for the default hotkey",
                    granted: hasInputMonitoring,
                    action: { 
                        AccessibilityPermission.requestInputMonitoring()
                        openInputMonitoringSettings() 
                    }
                )
            }
            .padding(.horizontal, 20)
            
            if hasRequiredPermissions {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PastaTheme.success)
                    Text("All set!")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PastaTheme.success)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(PastaTheme.success.opacity(0.1), in: Capsule())
            } else {
                Text("Tip: You may need to restart Pasta after granting permissions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .padding(.horizontal, 40)
    }
    
    private func permissionRow(title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(granted ? PastaTheme.success.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: granted ? "checkmark" : "lock.open")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(granted ? PastaTheme.success : .orange)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if !granted {
                Button("Enable") {
                    action()
                }
                .buttonStyle(PillButtonStyle(color: .orange))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: PastaTheme.Radius.large, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: PastaTheme.Radius.large, style: .continuous)
                        .stroke(granted ? PastaTheme.success.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
    
    // MARK: - Ready Step
    
    private var readyStep: some View {
        ScrollView(.vertical) {
            VStack(spacing: 18) {
                // Keep the completion footer outside this scroll view. The
                // shortcut reference can grow as commands are added without
                // ever pushing the only visible dismissal control off-screen.
                ZStack {
                    Circle()
                        .fill(PastaTheme.success.opacity(0.1))
                        .frame(width: 64, height: 64)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(PastaTheme.success)
                        .symbolEffect(.bounce, value: step == .ready)
                }
                
                VStack(spacing: 8) {
                    Text("You're Ready!")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))

                    Text("Press **⌃⌘V** anytime to open Pasta")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                
                // Quick reference card
                VStack(spacing: 10) {
                    quickRefRow(keys: "⌃⌘V", action: "Open Pasta")
                    quickRefRow(keys: "↩︎", action: "Paste selected")
                    quickRefRow(keys: ShortcutHints.pastePlainText.keys, action: "Paste as plain text")
                    quickRefRow(keys: "!", action: "Enter command mode")
                    quickRefRow(keys: "→", action: "Open preview panel")
                    quickRefRow(keys: "⌘1-⌘9", action: "Quick paste by slot")
                    quickRefRow(keys: "⌘⌫", action: "Delete clip")
                    quickRefRow(keys: "esc", action: "Close")
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: PastaTheme.Radius.large, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .frame(maxWidth: 260)

                Text("You can reopen this walkthrough from Settings → General anytime.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 40)
        }
    }
    
    private func quickRefRow(keys: String, action: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            
            Text(action)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            
            Spacer()
        }
    }
    
    // MARK: - Navigation Footer
    
    private var navigationFooter: some View {
        HStack {
            // Back button (except on first step)
            if step != .welcome {
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        if let prev = Step(rawValue: step.rawValue - 1) {
                            step = prev
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            
            // Skip (only on features step)
            if step == .features {
                Button("Skip tips") {
                    withAnimation(.spring(response: 0.35)) {
                        step = .permissions
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .padding(.trailing, 12)
            }
            
            // Primary action button
            Button {
                advanceStep()
            } label: {
                HStack(spacing: 6) {
                    Text(primaryButtonTitle)
                    if step != .ready {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            .buttonStyle(PillButtonStyle(color: currentAccentColor))
            .keyboardShortcut(.defaultAction)
        }
    }
    
    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .features: return "Continue"
        case .permissions: return hasRequiredPermissions ? "Continue" : "Skip for now"
        case .ready: return "Start Using Pasta"
        }
    }
    
    private func advanceStep() {
        withAnimation(.spring(response: 0.35)) {
            switch step {
            case .welcome:
                step = .features
            case .features:
                step = .permissions
            case .permissions:
                step = .ready
            case .ready:
                onComplete(.completed)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func refreshTrust() {
        hasAccessibility = AccessibilityPermission.isTrusted()
        hasInputMonitoring = AccessibilityPermission.hasInputMonitoring()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
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

    private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Feature Tip Model

private struct FeatureTip {
    let icon: String
    let title: String
    let description: String
    let accent: Color
}

// MARK: - Pill Button Style

private struct PillButtonStyle: ButtonStyle {
    let color: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(color)
                    .shadow(color: color.opacity(0.3), radius: 8, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}
