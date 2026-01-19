import PastaCore
import SwiftUI

public struct DeleteConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    public let entry: ClipboardEntry?
    public let onConfirm: () -> Void

    public init(entry: ClipboardEntry?, onConfirm: @escaping () -> Void) {
        self.entry = entry
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete entry?")
                .font(.headline)

            if let entry {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.contentType.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.body)
                        .lineLimit(6)
                        .textSelection(.enabled)

                    Text(entry.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("No selection")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Delete", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .disabled(entry == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

#Preview {
    DeleteConfirmationView(entry: ClipboardEntry(content: "Hello world", contentType: .text)) {}
}
