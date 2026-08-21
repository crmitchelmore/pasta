import AppKit
import Foundation
import ImageIO

enum ImageDownsampler {
    static func load(path: String, maxPixelSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

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
    /// main-panel previews), keyed by path + requested pixel size. Stored
    /// images are immutable (one file per image, content-hashed name), so no
    /// invalidation is needed; NSCache evicts under memory pressure.
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
