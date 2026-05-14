import PastaCore
import SwiftUI

// MARK: - Command Row

struct CommandRow: View {
    let command: Command
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Command icon
            Image(systemName: command.icon)
                .font(.title3)
                .foregroundStyle(command.isDestructive ? .red : .orange)
                .frame(width: 28)

            // Command info
            VStack(alignment: .leading, spacing: 2) {
                Text("!\(command.trigger)")
                    .font(.body.monospaced())
                    .fontWeight(.medium)

                HStack(spacing: 6) {
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Category badge
            Text(command.category.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

            // Keyboard shortcut hint
            Text("⌘\(index)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.orange.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Section Header

struct QuickSearchSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            if title == "Pinned" {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
