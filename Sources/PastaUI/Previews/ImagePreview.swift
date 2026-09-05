import AppKit
import SwiftUI

struct ImagePreview: View {
    let source: ClipboardImageSource

    /// Longest edge of the decoded preview, in pixels.
    private static let maxPixelSize: CGFloat = 1600

    @State private var image: NSImage?
    @State private var loadedSource: ClipboardImageSource?

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
        .onChange(of: source) { _, newSource in
            loadImage(from: newSource)
        }
        .overlay {
            if image == nil {
                ContentUnavailableView(
                    "Missing image",
                    systemImage: "photo",
                    description: Text("The image could not be loaded.")
                )
                .opacity(0) // keeps layout stable while loading
            }
        }
    }

    private func loadImageIfNeeded() {
        guard loadedSource != source else { return }
        loadImage(from: source)
    }

    private func loadImage(from source: ClipboardImageSource) {
        loadedSource = source

        // Selecting back and forth between entries must not re-read and
        // re-decode the file every time; the shared cache serves repeats
        // instantly.
        if let cached = ImageDownsampler.cached(source: source, maxPixelSize: Self.maxPixelSize) {
            image = cached
            return
        }

        image = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ImageDownsampler.cachedLoad(source: source, maxPixelSize: Self.maxPixelSize)
            DispatchQueue.main.async {
                // A slow decode must not overwrite a newer remote image.
                if loadedSource == source {
                    self.image = loaded
                }
            }
        }
    }
}
