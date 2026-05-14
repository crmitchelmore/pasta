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

    @State private var image: NSImage?
    @State private var quickLookURL: URL?

    private var isImage: Bool {
        preview.fileType == .image
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
            if isImage && preview.exists && image == nil {
                let path = preview.path
                DispatchQueue.global(qos: .userInitiated).async {
                    let loaded = ImageDownsampler.load(path: path, maxPixelSize: 1200) ?? NSImage(contentsOfFile: path)
                    DispatchQueue.main.async {
                        self.image = loaded
                    }
                }
            }
        }
    }
}
