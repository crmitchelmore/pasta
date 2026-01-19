import PastaCore
import SwiftUI

public struct BulkDeleteView: View {
    @Environment(\.dismiss) private var dismiss

    public let entries: [ClipboardEntry]
    public let now: Date
    public let onConfirm: (Int) -> Void

    @State private var minutes: Int = 15

    public init(entries: [ClipboardEntry], now: Date = Date(), onConfirm: @escaping (Int) -> Void) {
        self.entries = entries
        self.now = now
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete recent entries")
                .font(.headline)

            Text("Deletes entries copied within the last X minutes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Time", selection: $minutes) {
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("1 hr").tag(60)
                Text("Custom").tag(-1)
            }
            .pickerStyle(.segmented)

            if minutes == -1 {
                Stepper(value: $customMinutes, in: 1...720, step: 1) {
                    Text("Last \(customMinutes) minutes")
                        .font(.body)
                }
            }

            Text("Will delete: \(candidateCount) entr\(candidateCount == 1 ? "y" : "ies")")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Delete", role: .destructive) {
                    onConfirm(effectiveMinutes)
                    dismiss()
                }
                .disabled(candidateCount == 0)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    @State private var customMinutes: Int = 10

    private var effectiveMinutes: Int {
        if minutes == -1 { return customMinutes }
        return minutes
    }

    private var candidateCount: Int {
        let threshold = now.addingTimeInterval(TimeInterval(-effectiveMinutes * 60))
        return entries.filter { $0.timestamp >= threshold }.count
    }
}

#Preview {
    BulkDeleteView(entries: (0..<50).map { idx in
        var e = ClipboardEntry(content: "Item \(idx)", contentType: .text)
        e.timestamp = Date().addingTimeInterval(-Double(idx) * 60)
        return e
    }) { _ in }
}
