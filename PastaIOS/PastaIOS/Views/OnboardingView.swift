import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            Image(systemName: "clipboard.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
                .padding(.bottom, 24)

            // Title
            Text("Welcome to Pasta")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 8)

            Text("Your clipboard history, everywhere")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)

            // Features
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "arrow.triangle.2.circlepath.icloud",
                    title: "Sync with your Mac",
                    description: "Clipboard entries from Pasta on your Mac sync automatically via iCloud."
                )
                FeatureRow(
                    icon: "magnifyingglass",
                    title: "Fast search",
                    description: "Find any copied text, URL, code snippet, or email in milliseconds."
                )
                FeatureRow(
                    icon: "doc.on.doc",
                    title: "Copy & share",
                    description: "Tap any entry to copy it, or share it with other apps."
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            // iCloud notice
            if !appState.iCloudAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    Text("iCloud is required for syncing. Please sign in to iCloud in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            // Continue button
            Button {
                appState.completeOnboarding()
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
