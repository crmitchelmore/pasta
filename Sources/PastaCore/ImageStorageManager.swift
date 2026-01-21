import CryptoKit
import Foundation
import os.log

#if canImport(AppKit)
import AppKit
#endif

public final class ImageStorageManager {
    private let imagesDirectoryURL: URL

    public init(imagesDirectoryURL: URL = ImageStorageManager.defaultImagesDirectoryURL()) throws {
        self.imagesDirectoryURL = imagesDirectoryURL
        do {
            try FileManager.default.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
            PastaLogger.storage.info("Image storage initialized at \(imagesDirectoryURL.path)")
        } catch {
            PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to create images directory")
            throw PastaError.storageUnavailable(path: imagesDirectoryURL.path)
        }
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
            do {
                try data.write(to: url, options: [.atomic])
                PastaLogger.storage.debug("Saved image to \(url.path) (\(data.count) bytes)")
            } catch let error as NSError {
                // Check for disk full errors
                if error.domain == NSCocoaErrorDomain && (error.code == NSFileWriteOutOfSpaceError || error.code == NSFileWriteVolumeReadOnlyError) {
                    PastaLogger.storage.error("Disk full or read-only when saving image")
                    throw PastaError.diskFull(path: url.path, underlying: error)
                }
                PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to save image")
                throw PastaError.imageSaveFailed(underlying: error)
            }
        }

        return url.path
    }

    #if canImport(AppKit)
    public func loadImage(path: String) -> NSImage? {
        if let image = NSImage(contentsOfFile: path) {
            return image
        }
        // Return placeholder for missing files
        PastaLogger.storage.debug("Image not found at \(path), returning placeholder")
        return NSImage(systemSymbolName: "photo", accessibilityDescription: "Missing image")
    }
    #else
    public func loadImage(path: String) -> Any? {
        nil
    }
    #endif

    public func deleteImage(path: String) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                PastaLogger.storage.debug("Deleted image at \(path)")
            } catch {
                PastaLogger.logError(error, logger: PastaLogger.storage, context: "Failed to delete image")
                throw error
            }
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
