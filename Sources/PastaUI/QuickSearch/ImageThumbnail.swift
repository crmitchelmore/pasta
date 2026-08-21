import AppKit
import SwiftUI

// MARK: - Image Thumbnail

struct ImageThumbnail: View {
    let path: String
    let size: CGFloat
    @State private var image: NSImage?
    @State private var loadedPath: String = ""

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: path) { _, newPath in
            loadImage(from: newPath)
        }
    }

    private func loadImageIfNeeded() {
        guard loadedPath != path else { return }
        loadImage(from: path)
    }

    private func loadImage(from imagePath: String) {
        loadedPath = imagePath
        let pixelSize = size * 2 // retina

        if let cached = ImageDownsampler.cached(path: imagePath, maxPixelSize: pixelSize) {
            image = cached
            return
        }

        image = nil
        Task.detached(priority: .userInitiated) {
            let thumbnail = ImageDownsampler.cachedLoad(path: imagePath, maxPixelSize: pixelSize)
            await MainActor.run {
                if loadedPath == imagePath {
                    image = thumbnail
                }
            }
        }
    }
}
