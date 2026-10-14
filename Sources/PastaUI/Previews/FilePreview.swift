import AppKit
import PastaDetectors
import SwiftUI

// File-level struct for file path preview data
struct FilePathPreviewData {
    var path: String
    var filename: String
    var fileType: FilePathDetector.FileType
    var mimeType: String?
    var exists: Bool
}

struct FilePreview: View {
    let preview: FilePathPreviewData

    /// Longest edge of the decoded preview, in pixels.
    private static let maxPixelSize: CGFloat = 1200

    @State private var image: NSImage?
    /// Path the current `image` belongs to; the panel reuses this view when
    /// the selection moves to another file entry.
    @State private var loadedPath: String?
    @State private var quickLookURL: URL?

    private var isImage: Bool {
        preview.fileType == .image
    }

    private var imagePathToLoad: String? {
        isImage && preview.exists ? preview.path : nil
    }

    private var systemImageName: String {
        switch preview.fileType {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.richtext"
        case .code: return "doc.text"
        case .archive: return "archivebox"
        case .data: return "cylinder"
        case .executable: return "app"
        case .font: return "textformat"
        case .other: return "doc"
        }
    }

    private var fileTypeColor: Color {
        switch preview.fileType {
        case .image: return .purple
        case .video: return .pink
        case .audio: return .orange
        case .document: return .blue
        case .code: return .green
        case .archive: return .brown
        case .data: return .cyan
        case .executable: return .red
        case .font: return .indigo
        case .other: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // File info header
            HStack(spacing: 12) {
                Image(systemName: systemImageName)
                    .font(.largeTitle)
                    .foregroundStyle(fileTypeColor)
                    .frame(width: 50, height: 50)
                    .background(fileTypeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.filename)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text(preview.fileType.rawValue.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(fileTypeColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(fileTypeColor)

                        if let mime = preview.mimeType {
                            Text(mime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !preview.exists {
                            Label("Not found", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()
            }

            // Path
            Text(preview.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)

            // Image preview if it's an image file
            if isImage && preview.exists {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 100)
                }
            }

            // Actions
            if preview.exists {
                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: preview.path)])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: preview.path))
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onAppear {
            loadImage(for: imagePathToLoad)
        }
        .onChange(of: imagePathToLoad) { _, newPath in
            loadImage(for: newPath)
        }
    }

    private func loadImage(for path: String?) {
        guard loadedPath != path || (path != nil && image == nil) else { return }
        loadedPath = path
        image = nil
        guard let path else { return }
        // Off-main: the cache key stats the file, and a miss decodes it.
        // Reselecting the same unchanged file is then a cache hit.
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ImageDownsampler.cachedLoad(userFilePath: path, maxPixelSize: Self.maxPixelSize)
            DispatchQueue.main.async {
                // A slow decode must not overwrite a newer selection's image.
                if loadedPath == path {
                    self.image = loaded
                }
            }
        }
    }
}
