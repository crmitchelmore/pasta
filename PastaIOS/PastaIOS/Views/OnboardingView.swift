import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    private var isReplay: Bool {
        appState.hasCompletedOnboarding
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

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

            Text("Your iPhone clipboard companion for Pasta on Mac")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)

            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "arrow.triangle.2.circlepath.icloud",
                    title: "Built for Mac + iPhone",
                    description: "Pasta on iPhone is a companion app: it mirrors clipboard history from your Mac through iCloud."
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
                    description: "Your data stays in iCloud/local storage tied to your Apple account."
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            // iCloud notice
            if !appState.iCloudAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    Text("iCloud is needed for cross-device sync. You can still browse local entries while offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            VStack(spacing: 8) {
                // Continue button
                Button {
                    if isReplay {
                        appState.dismissOnboarding()
                    } else {
                        appState.completeOnboarding()
                    }
                } label: {
                    Text(isReplay ? "Done" : "Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !isReplay {
                    Text("You can replay this any time from Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
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
