import SwiftUI
import PastaCore

struct EntryRowView: View {
    let entry: ClipboardEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.contentType.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(entry.contentType.tintColor)
                .frame(width: 28, height: 28)
                .background(entry.contentType.tintColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.content.prefix(200))
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(entry.contentType.displayName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(entry.contentType.tintColor.opacity(0.12))
                        .foregroundStyle(entry.contentType.tintColor)
                        .clipShape(Capsule())

                    if let sourceApp = entry.sourceApp {
                        Text(sourceApp.components(separatedBy: ".").last ?? sourceApp)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(entry.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if entry.copyCount > 1 {
                        Text("×\(entry.copyCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
