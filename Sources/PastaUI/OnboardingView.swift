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
    @State private var tipAutoAdvance: Bool = true

    private let onComplete: (Completion) -> Void
    
    private var hasAllPermissions: Bool {
        hasAccessibility && hasInputMonitoring
    }
    
    private let featureTips: [FeatureTip] = [
        FeatureTip(
            icon: "clock.arrow.circlepath",
            title: "Clipboard History",
            description: "Everything you copy is saved and searchable. Never lose that link again.",
            accent: Color(red: 1.0, green: 0.45, blue: 0.35)
        ),
        FeatureTip(
            icon: "magnifyingglass",
            title: "Instant Search",
            description: "Find any clip in milliseconds. Just start typing.",
            accent: Color(red: 0.35, green: 0.65, blue: 0.95)
        ),
        FeatureTip(
            icon: "keyboard",
            title: "Quick Paste",
            description: "Press ⌃⌘V, pick a clip, hit Return. Pasted instantly.",
            accent: Color(red: 0.55, green: 0.78, blue: 0.25)
        ),
        FeatureTip(
            icon: "iphone.and.arrow.right.inward",
            title: "Continuity Sync",
            description: "Copies from your iPhone appear automatically via Handoff.",
            accent: Color(red: 0.75, green: 0.45, blue: 0.95)
        ),
        FeatureTip(
            icon: "tag",
            title: "Smart Detection",
            description: "URLs, emails, code, colors — automatically tagged and organized.",
            accent: Color(red: 0.94, green: 0.74, blue: 0.18)
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
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        case .ready: return Color.green
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
                            tipAutoAdvance = false
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
        .onAppear {
            startTipAutoAdvance()
        }
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
                    .symbolEffect(.pulse.byLayer, options: .repeating)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tip.accent.opacity(0.2), lineWidth: 1)
                }
        }
    }
    
    private func startTipAutoAdvance() {
        guard tipAutoAdvance else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard tipAutoAdvance, step == .features else { return }
            withAnimation(.spring(response: 0.35)) {
                featureTipIndex = (featureTipIndex + 1) % featureTips.count
            }
            startTipAutoAdvance()
        }
    }
    
    // MARK: - Permissions Step
    
    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 8) {
                Text("Quick Setup")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                
                Text("Two permissions for the full experience")
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
                        openAccessibilitySettings() 
                    }
                )
                
                permissionRow(
                    title: "Input Monitoring",
                    subtitle: "Global hotkey support",
                    granted: hasInputMonitoring,
                    action: { 
                        AccessibilityPermission.requestInputMonitoring()
                        openInputMonitoringSettings() 
                    }
                )
            }
            .padding(.horizontal, 20)
            
            if hasAllPermissions {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All set!")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.green.opacity(0.1), in: Capsule())
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
                    .fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: granted ? "checkmark" : "lock.open")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(granted ? .green : .orange)
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(granted ? Color.green.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
    
    // MARK: - Ready Step
    
    private var readyStep: some View {
        VStack(spacing: 28) {
            Spacer()
            
            // Success animation
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: step == .ready)
            }
            
            VStack(spacing: 12) {
                Text("You're Ready!")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                
                Text("Press **⌃⌘V** anytime to open Pasta")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            
            // Quick reference card
            VStack(spacing: 12) {
                quickRefRow(keys: "⌃⌘V", action: "Open Pasta")
                quickRefRow(keys: "↩︎", action: "Paste selected")
                quickRefRow(keys: "⌘⌫", action: "Delete clip")
                quickRefRow(keys: "esc", action: "Close")
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .frame(maxWidth: 260)
            
            Spacer()
        }
        .padding(.horizontal, 40)
    }
    
    private func quickRefRow(keys: String, action: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            
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
                    tipAutoAdvance = false
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
        case .permissions: return hasAllPermissions ? "Continue" : "Skip for now"
        case .ready: return "Start Using Pasta"
        }
    }
    
    private func advanceStep() {
        withAnimation(.spring(response: 0.35)) {
            switch step {
            case .welcome:
                step = .features
            case .features:
                tipAutoAdvance = false
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
