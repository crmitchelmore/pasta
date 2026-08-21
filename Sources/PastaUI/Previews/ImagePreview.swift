import AppKit
import SwiftUI

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

        // Selecting back and forth between entries must not re-read and
        // re-decode the file every time; the shared cache serves repeats
        // instantly.
        if let cached = ImageDownsampler.cached(path: imagePath, maxPixelSize: Self.maxPixelSize) {
            image = cached
            return
        }

        image = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ImageDownsampler.cachedLoad(path: imagePath, maxPixelSize: Self.maxPixelSize)
            DispatchQueue.main.async {
                // Only update if path hasn't changed
                if loadedPath == imagePath {
                    self.image = loaded
                }
            }
        }
    }
}
