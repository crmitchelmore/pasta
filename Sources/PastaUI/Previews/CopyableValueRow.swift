import AppKit
import PastaCore
import SwiftUI

/// Click-to-copy row for a single extracted value. Copies `value` to the
/// pasteboard and flashes a checkmark for 1.5 s.
///
/// Used by the main panel's per-type extracted-values list (`.list`) and by the
/// preview panel's "Detected Items" grid (`.compact`).
struct CopyableValueRow: View {
    enum Style {
        /// Full-width list row: body text, two lines, optional source preview.
        case list
        /// Compact grid chip: caption text, single line, tinted background.
        case compact
    }

    let type: ContentType
    let value: String
    let displayValue: String
    /// Preview of the entry the value came from (`.list` only); nil when the
    /// value IS the primary entry.
    var sourcePreview: String? = nil
    let style: Style

    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard()
        } label: {
            HStack(spacing: style == .list ? 10 : 8) {
                Image(systemName: type.systemImageName)
                    .font(style == .list ? nil : .caption)
                    .foregroundStyle(type.tint)
                    .frame(width: style == .list ? 20 : 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayValue)
                        .font(.system(style == .list ? .body : .caption, design: .monospaced))
                        .lineLimit(style == .list ? 2 : 1)
                        .truncationMode(.middle)

                    if style == .list, let sourcePreview {
                        Text("from: \(sourcePreview)...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: copied ? (style == .list ? "checkmark.circle.fill" : "checkmark") : "doc.on.doc")
                    .font(style == .list ? .caption : .caption2)
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, style == .list ? 12 : 10)
            .padding(.vertical, style == .list ? 8 : 6)
            .background { background }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy: \(value)")
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .list:
            Color(nsColor: .controlBackgroundColor)
        case .compact:
            RoundedRectangle(cornerRadius: 6).fill(type.tint.opacity(0.1))
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) {
            copied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                copied = false
            }
        }
    }
}
