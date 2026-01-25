import PastaCore
import SwiftUI

public struct TipJarView: View {
    public init() {}
    
    public var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Text("💝")
                        .font(.system(size: 48))
                    
                    Text("Support Pasta")
                        .font(.headline)
                    
                    Text("Pasta is free and open source. If you find it useful, consider supporting its development!")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            
            Section {
                SupportLinkRow(
                    icon: "heart.fill",
                    iconColor: .pink,
                    title: "GitHub Sponsors",
                    subtitle: "Monthly or one-time support",
                    url: TipJarLinks.githubSponsors
                )
                
                SupportLinkRow(
                    icon: "cup.and.saucer.fill",
                    iconColor: .orange,
                    title: "Ko-fi",
                    subtitle: "Buy me a coffee",
                    url: TipJarLinks.kofi
                )
            } header: {
                Label("Support Development", systemImage: "heart.circle")
            }
            
            Section {
                SupportLinkRow(
                    icon: "star.fill",
                    iconColor: .yellow,
                    title: "Star on GitHub",
                    subtitle: "Help others discover Pasta",
                    url: TipJarLinks.githubRepo
                )
            } header: {
                Label("Spread the Word", systemImage: "megaphone")
            }
            
            Section {
                Text("Thank you for using Pasta! Your support helps keep the project alive and growing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Support Link Row

private struct SupportLinkRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let url: URL
    
    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    TipJarView()
        .frame(width: 520, height: 500)
}
