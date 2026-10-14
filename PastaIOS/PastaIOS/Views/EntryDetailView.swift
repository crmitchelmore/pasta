import ImageIO
import SwiftUI
import PastaCore

struct EntryDetailView: View {
    private struct DetectedItemsRequest: Equatable {
        let metadata: String?
        let limit: Int
    }

    private enum Limits {
        // Matches the macOS preview. SwiftUI lays out the whole string, so
        // multi-megabyte entries froze the screen. Copy and share stay full.
        static let inlineContentCharacters = 12_000
        // Wider images are downsampled to this, which still exceeds every
        // iPhone and iPad screen; narrower ones decode at full resolution.
        static let maxImagePixelWidth: CGFloat = 2_048
    }

    private enum ImageState {
        case loading
        case loaded(UIImage)
        case unavailable
    }

    /// Re-decodes when sync later downloads or replaces this entry's image.
    private struct ImageDecodeKey: Equatable {
        let entryID: UUID
        let byteCount: Int
    }

    let entry: ClipboardEntry
    // Decoded once off the main thread. `UIImage(data:)` in `body` re-decoded
    // the full image on every re-render, such as the copy toast.
    @State private var imageState: ImageState
    @State private var showCopiedFeedback = false
    @State private var showShareSheet = false
    @State private var detectedItems: [MetadataParser.ExtractedValue] = []
    @State private var detectedItemLimit = 100
    @State private var hasMoreDetectedItems = false

    init(entry: ClipboardEntry) {
        self.entry = entry
        let hasImageData = entry.rawData.map { !$0.isEmpty } ?? false
        _imageState = State(initialValue: hasImageData ? .loading : .unavailable)
    }

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
                        Text(entry.isMixedContent ? "Mixed \u{00b7} \(entry.contentType.displayName)" : entry.contentType.displayName)
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

                if !detectedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detected Items")
                            .font(.headline)
                        ForEach(detectedItems) { item in
                            HStack {
                                Text(item.displayValue)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                Spacer()
                                Button {
                                    copyToClipboard(item.value)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .accessibilityLabel("Copy \(item.type.displayName)")
                            }
                        }
                        if hasMoreDetectedItems {
                            Button("Show 100 more") { detectedItemLimit += 100 }
                        }
                    }
                }

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
        .task(id: DetectedItemsRequest(metadata: entry.metadata, limit: detectedItemLimit)) {
            let metadata = entry.metadata
            let limit = detectedItemLimit
            let items = await Task.detached(priority: .utility) {
                MetadataParser.extractAllValues(from: metadata, limit: limit + 1, content: entry.content)
            }.value
            guard !Task.isCancelled else { return }
            detectedItems = Array(items.prefix(limit))
            hasMoreDetectedItems = items.count > limit
        }
        .task(id: ImageDecodeKey(entryID: entry.id, byteCount: entry.rawData?.count ?? 0)) {
            guard entry.contentType == .image || entry.contentType == .screenshot,
                  let data = entry.rawData, !data.isEmpty else {
                imageState = .unavailable
                return
            }
            if case .unavailable = imageState { imageState = .loading }
            let image = await Task.detached(priority: .userInitiated) {
                Self.decodeImage(data)
            }.value
            guard !Task.isCancelled else { return }
            imageState = image.map(ImageState.loaded) ?? .unavailable
        }
    }

    nonisolated private static func decodeImage(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }),
              pixelWidth > 0, pixelHeight > 0 else {
            return UIImage(data: data)
        }
        // EXIF orientations 5-8 swap the displayed width and height.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let displayWidth = orientation >= 5 ? pixelHeight : pixelWidth
        let longEdge = max(pixelWidth, pixelHeight)
        let scale = min(1, Limits.maxImagePixelWidth / displayWidth)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: (longEdge * scale).rounded(.up)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: image)
    }

    private var contentPreview: (text: String, isTruncated: Bool) {
        let content = entry.content
        // Step at most the limit; `count` would walk the whole string.
        guard let end = content.index(content.startIndex, offsetBy: Limits.inlineContentCharacters, limitedBy: content.endIndex),
              end < content.endIndex else {
            return (content, false)
        }
        return (String(content[..<end]), true)
    }

    private var truncationNote: some View {
        Text("Showing the first \(Limits.inlineContentCharacters.formatted()) characters for performance. Copy or share to get the full text.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("detail.truncationNote")
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
        let preview = contentPreview
        return VStack(alignment: .leading, spacing: 8) {
            Text(preview.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if preview.isTruncated { truncationNote }
        }
    }

    private var codeContent: some View {
        let preview = contentPreview
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(preview.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if preview.isTruncated { truncationNote }
        }
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
        switch imageState {
        case .loaded(let uiImage):
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        case .unavailable:
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

    private func copyToClipboard(_ value: String? = nil) {
        UIPasteboard.general.string = value ?? entry.content
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
