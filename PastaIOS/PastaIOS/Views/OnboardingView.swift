import SwiftUI
import PastaSync

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var syncManager: SyncManager

    private var isReplay: Bool {
        appState.hasCompletedOnboarding
    }

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {

            // Icon
            Image(systemName: "clipboard.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
                .padding(.bottom, 24)

            // Title
            Text(isReplay ? "Pasta Walkthrough" : "Welcome to Pasta")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 8)
                .accessibilityIdentifier("onboarding.title")

            Text("Your iPhone clipboard companion for Pasta on Mac")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)

            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "arrow.triangle.2.circlepath.icloud",
                    title: "Built for Mac + iPhone",
                    description: "Choose iCloud sync to access clipboard history from your Mac on your iPhone."
                )
                FeatureRow(
                    icon: "magnifyingglass",
                    title: "Fast search",
                    description: "Find copied text, URLs, and snippets quickly when you need them on mobile."
                )
                FeatureRow(
                    icon: "doc.on.doc",
                    title: "Copy & share",
                    description: "Tap any entry to copy it, or share it with other apps."
                )
                FeatureRow(
                    icon: "lock.shield",
                    title: "Private by default",
                    description: "Clipboard history stays on this iPhone until you choose to enable iCloud sync."
                )
            }
            .padding(.horizontal, 24)

            Color.clear.frame(height: 24)

            if !isReplay {
                Text("Enable iCloud sync to upload your existing and future clipboard history to your private iCloud account and receive history from your Mac. Sync is off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("onboarding.syncExplanation")
            }

            VStack(spacing: 8) {
                if !isReplay {
                    Button("Enable iCloud Sync") {
                        appState.setICloudSyncEnabled(true, syncManager: syncManager)
                        appState.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding.enableSync")
                }
                // Local-only continuation never grants upload consent.
                Button {
                    if isReplay {
                        appState.dismissOnboarding()
                    } else {
                        appState.completeOnboarding()
                    }
                } label: {
                    Text(isReplay ? "Done" : "Continue on This iPhone")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.primaryButton")

                if !isReplay {
                    Text("You can replay this any time from Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .padding(.top, 24)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
