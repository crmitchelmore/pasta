import AppKit
import SwiftUI

// MARK: - Image Thumbnail

private let thumbnailCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 300
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
}()

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
        let cacheKey = NSString(string: imagePath)

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            image = cached
            return
        }

        image = nil
        let pixelSize = size * 2 // retina
        Task.detached(priority: .userInitiated) {
            let thumbnail = ImageDownsampler.load(path: imagePath, maxPixelSize: pixelSize)
            if let thumbnail {
                let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                thumbnailCache.setObject(thumbnail, forKey: cacheKey, cost: cost)
            }
            await MainActor.run {
                if loadedPath == imagePath {
                    image = thumbnail
                }
            }
        }
    }
}
