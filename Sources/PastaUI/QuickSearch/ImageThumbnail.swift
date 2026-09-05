import AppKit
import SwiftUI

// MARK: - Image Thumbnail

struct ImageThumbnail: View {
    let source: ClipboardImageSource
    let size: CGFloat
    @State private var image: NSImage?
    @State private var loadedSource: ClipboardImageSource?

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
        .onChange(of: source) { _, newSource in
            loadImage(from: newSource)
        }
    }

    private func loadImageIfNeeded() {
        guard loadedSource != source else { return }
        loadImage(from: source)
    }

    private func loadImage(from source: ClipboardImageSource) {
        loadedSource = source
        let pixelSize = size * 2 // retina

        if let cached = ImageDownsampler.cached(source: source, maxPixelSize: pixelSize) {
            image = cached
            return
        }

        image = nil
        Task.detached(priority: .userInitiated) {
            let thumbnail = ImageDownsampler.cachedLoad(source: source, maxPixelSize: pixelSize)
            await MainActor.run {
                if loadedSource == source {
                    image = thumbnail
                }
            }
        }
    }
}
