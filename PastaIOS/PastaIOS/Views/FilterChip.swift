import SwiftUI
import PastaCore

struct FilterChip: View {
    let title: String
    var icon: String?
    var count: Int?
    var tintColor: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white : (tintColor ?? .primary))
                }
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? (tintColor ?? Color.accentColor) : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(count.map { ", \($0) items" } ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
