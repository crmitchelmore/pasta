import CryptoKit
import Foundation

#if canImport(AppKit)
import AppKit
#endif

public final class ImageStorageManager {
    private let imagesDirectoryURL: URL

    public init(imagesDirectoryURL: URL = ImageStorageManager.defaultImagesDirectoryURL()) throws {
        self.imagesDirectoryURL = imagesDirectoryURL
        try FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
    }

    public static func defaultImagesDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pasta", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
    }

    /// Saves image data to disk and returns the absolute file path.
    /// Uses the SHA256 of the data to generate a stable, unique filename.
    public func saveImage(_ data: Data) throws -> String {
        let filename = "\(ImageStorageManager.sha256Hex(data)).dat"
        let url = imagesDirectoryURL.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic])
        }

        return url.path
    }

    #if canImport(AppKit)
    public func loadImage(path: String) -> NSImage? {
        NSImage(contentsOfFile: path)
    }
    #else
    public func loadImage(path: String) -> Any? {
        nil
    }
    #endif

    public func deleteImage(path: String) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func totalStorageBytes() throws -> Int64 {
        let urls = try FileManager.default.contentsOfDirectory(
            at: imagesDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var total: Int64 = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
