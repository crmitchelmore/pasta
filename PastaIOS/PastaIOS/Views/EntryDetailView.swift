import SwiftUI
import PastaCore

struct EntryDetailView: View {
    let entry: ClipboardEntry
    @State private var showCopiedFeedback = false
    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: entry.contentType.iconName)
                        .font(.title2)
                        .foregroundStyle(entry.contentType.tintColor)
                        .frame(width: 44, height: 44)
                        .background(entry.contentType.tintColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.contentType.displayName)
                            .font(.headline)
                        Text(entry.timestamp, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Metadata
                if let sourceApp = entry.sourceApp {
                    LabeledContent("Source", value: sourceApp.components(separatedBy: ".").last ?? sourceApp)
                }
                if entry.copyCount > 1 {
                    LabeledContent("Copied", value: "\(entry.copyCount) times")
                }

                Divider()

                // Content
                contentView
            }
            .padding()
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                }

                ShareLink(item: entry.content) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .overlay {
            if showCopiedFeedback {
                copiedToast
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        if entry.contentType == .image || entry.contentType == .screenshot {
            imageContent
        } else if entry.contentType == .code || entry.contentType == .shellCommand {
            codeContent
        } else if entry.contentType == .url {
            urlContent
        } else {
            textContent
        }
    }

    private var textContent: some View {
        Text(entry.content)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var codeContent: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(entry.content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var urlContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = URL(string: entry.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "globe")
                        Text(entry.content)
                            .lineLimit(3)
                    }
                }
            } else {
                textContent
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let data = entry.rawData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Image not yet downloaded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        UIPasteboard.general.string = entry.content
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        showCopiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedFeedback = false
        }
    }

    private var copiedToast: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Copied to clipboard")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
            .padding(.top, 8)
            Spacer()
        }
    }
}
