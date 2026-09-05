import AppKit
import CryptoKit
import Foundation
import ImageIO
import PastaCore

/// Local captures usually have a file; downloaded images carry their bytes.
/// Keep either source in memory without creating files from view rendering.
enum ClipboardImageSource: Equatable, Sendable {
    case file(String)
    case data(Data)

    init?(entry: ClipboardEntry) {
        guard entry.contentType == .image || entry.contentType == .screenshot else { return nil }
        if let path = entry.imagePath {
            self = .file(path)
        } else if let data = entry.rawData, !data.isEmpty {
            self = .data(data)
        } else {
            return nil
        }
    }
}

enum ImageDownsampler {
    static func load(path: String, maxPixelSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

        return thumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(source: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Shared decode cache

    /// One cache for every decoded-image surface (quick-search thumbnails,
    /// main-panel previews), keyed by file path or data hash + requested pixel
    /// size. Stored files are immutable (content-hashed names), and changed
    /// downloaded bytes get a new key. NSCache evicts under memory pressure.
    private static let renderCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    /// Cache lookup only — safe to call on the main thread for a flash-free
    /// hit before scheduling a decode.
    static func cached(path: String, maxPixelSize: CGFloat) -> NSImage? {
        renderCache.object(forKey: cacheKey(path: path, maxPixelSize: maxPixelSize))
    }

    static func cached(source: ClipboardImageSource, maxPixelSize: CGFloat) -> NSImage? {
        // Hashing a downloaded blob can be expensive. Do it only in the
        // background loader, never during this main-thread fast path.
        guard case .file(let path) = source else { return nil }
        return cached(path: path, maxPixelSize: maxPixelSize)
    }

    static func cachedLoad(source: ClipboardImageSource, maxPixelSize: CGFloat) -> NSImage? {
        switch source {
        case .file(let path):
            return cachedLoad(path: path, maxPixelSize: maxPixelSize)
        case .data(let data):
            // Key by bytes, not entry UUID: a same-record remote update must
            // never reuse the previous image's decoded pixels.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let key = "data:\(digest)|\(Int(maxPixelSize))" as NSString
            if let hit = renderCache.object(forKey: key) { return hit }
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = thumbnail(source: imageSource, maxPixelSize: maxPixelSize) else { return nil }
            renderCache.setObject(image, forKey: key, cost: pixelCost(of: image))
            return image
        }
    }

    /// Cache lookup + decode + insert. Decodes from disk on a miss — call off
    /// the main thread.
    static func cachedLoad(path: String, maxPixelSize: CGFloat) -> NSImage? {
        let key = cacheKey(path: path, maxPixelSize: maxPixelSize)
        if let hit = renderCache.object(forKey: key) { return hit }
        guard let image = load(path: path, maxPixelSize: maxPixelSize) ?? NSImage(contentsOfFile: path) else {
            return nil
        }
        renderCache.setObject(image, forKey: key, cost: pixelCost(of: image))
        return image
    }

    private static func cacheKey(path: String, maxPixelSize: CGFloat) -> NSString {
        "\(path)|\(Int(maxPixelSize))" as NSString
    }

    /// Approximate decoded size in bytes, from PIXEL dimensions — NSImage.size
    /// is in points and undercounts 4-16x for high-DPI representations.
    private static func pixelCost(of image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }
}
