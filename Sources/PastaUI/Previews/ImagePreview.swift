import AppKit
import SwiftUI

struct ImagePreview: View {
    let path: String

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
        image = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = ImageDownsampler.load(path: imagePath, maxPixelSize: 1600) ?? NSImage(contentsOfFile: imagePath)
            DispatchQueue.main.async {
                // Only update if path hasn't changed
                if loadedPath == imagePath {
                    self.image = loaded
                }
            }
        }
    }
}
