import AppKit
import SwiftUI

/// Cache of decoded, display-sized preview images so selecting back and forth
/// between entries doesn't re-read and re-decode the file every time (same
/// pattern as the quick-search thumbnail cache, keyed by path + pixel size —
/// stored images are immutable, so no invalidation is needed).
private let previewImageCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 24
    cache.totalCostLimit = 128 * 1024 * 1024
    return cache
}()

struct ImagePreview: View {
    let path: String

    /// Longest edge of the decoded preview, in pixels.
    private static let maxPixelSize: CGFloat = 1600

    @State private var image: NSImage?
    @State private var loadedPath: String = ""

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: path) { _, newPath in
            loadImage(from: newPath)
        }
        .overlay {
            if image == nil {
                ContentUnavailableView(
                    "Missing image",
                    systemImage: "photo",
                    description: Text(path)
                )
                .opacity(0) // keeps layout stable while loading
            }
        }
    }

    private func loadImageIfNeeded() {
        guard loadedPath != path else { return }
        loadImage(from: path)
    }

    private func loadImage(from imagePath: String) {
        loadedPath = imagePath

        let cacheKey = NSString(string: "\(imagePath)|\(Int(Self.maxPixelSize))")
        if let cached = previewImageCache.object(forKey: cacheKey) {
            image = cached
            return
        }

        image = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ImageDownsampler.load(path: imagePath, maxPixelSize: Self.maxPixelSize) ?? NSImage(contentsOfFile: imagePath)
            if let loaded {
                let cost = Int(loaded.size.width * loaded.size.height * 4)
                previewImageCache.setObject(loaded, forKey: cacheKey, cost: cost)
            }
            DispatchQueue.main.async {
                // Only update if path hasn't changed
                if loadedPath == imagePath {
                    self.image = loaded
                }
            }
        }
    }
}
