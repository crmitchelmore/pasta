import AppKit
import PastaCore
import XCTest
@testable import PastaUI

final class RemoteImageRenderingTests: XCTestCase {
    @MainActor
    func testImageSourcesDecodeFromSyncedBytesOrFilesAndInvalidateOnChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteImageRendering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Local files decode from disk, are cached while unchanged and decode again after an edit.
        let url = directory.appendingPathComponent("photo.png")
        try png(width: 80, height: 40).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        let landscape = try XCTUnwrap(ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))
        XCTAssertTrue(landscape === ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))
        try png(width: 40, height: 80).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: url.path)
        let portrait = try XCTUnwrap(ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))
        XCTAssertFalse(landscape === portrait)
        let landscapeRep = try XCTUnwrap(landscape.representations.first)
        let portraitRep = try XCTUnwrap(portrait.representations.first)
        XCTAssertGreaterThan(landscapeRep.pixelsWide, landscapeRep.pixelsHigh)
        XCTAssertGreaterThan(portraitRep.pixelsHigh, portraitRep.pixelsWide)
        XCTAssertNil(ImageDownsampler.cachedLoad(userFilePath: directory.appendingPathComponent("missing.png").path, maxPixelSize: 32))

        let bytes = try png(width: 4, height: 4)
        let local = ClipboardEntry(content: "image", contentType: .image, rawData: bytes, imagePath: "/local/image.png")
        XCTAssertEqual(ClipboardImageSource(entry: local), .file("/local/image.png"))
        XCTAssertNil(ClipboardImageSource(entry: ClipboardEntry(content: "text", contentType: .text, rawData: bytes)))
        XCTAssertNil(ClipboardImageSource(entry: ClipboardEntry(content: "image", contentType: .image)))
        XCTAssertNil(ImageDownsampler.cachedLoad(source: .data(Data([0, 1, 2])), maxPixelSize: 24))

        let first = ClipboardEntry(content: "first", contentType: .text)
        var replacement = first
        replacement.content = "other"
        XCTAssertNotEqual(PreviewPanelView(entry: first), PreviewPanelView(entry: replacement))
        let image = ClipboardEntry(content: "image", contentType: .image, rawData: bytes)
        var newImage = image
        newImage.rawData = try png(width: 8, height: 4)
        XCTAssertNotEqual(PreviewPanelView(entry: image), PreviewPanelView(entry: newImage))
        XCTAssertEqual(PreviewPanelView(entry: newImage), PreviewPanelView(entry: newImage))

        // A synced image has bytes but no local file and must still render a thumbnail.
        let database = try DatabaseManager.inMemory()
        let remoteBytes = try png(width: 80, height: 40)
        let remote = ClipboardEntry(content: "remote image", contentType: .image, rawData: remoteBytes)
        try database.applySyncChanges(modified: [remote], deleted: [])
        let remoteRow = ClipboardRowData(from: try XCTUnwrap(try database.fetch(id: remote.id)))
        XCTAssertNil(remoteRow.imagePath)
        XCTAssertTrue(remoteRow.prefersImageThumbnail)
        let remoteSource = try XCTUnwrap(remoteRow.imageSource)
        XCTAssertEqual(remoteSource, .data(remoteBytes))
        let remoteRep = try XCTUnwrap(ImageDownsampler.cachedLoad(source: remoteSource, maxPixelSize: 20)?.representations.first)
        XCTAssertEqual(remoteRep.pixelsWide, 20)
        XCTAssertEqual(remoteRep.pixelsHigh, 10)

        // Replacing a synced record's image invalidates both the row and the decoded image.
        let screenshot = ClipboardEntry(content: "image", contentType: .screenshot, rawData: try png(width: 80, height: 40))
        let cache = ClipboardRowModelCache()
        try database.applySyncChanges(modified: [screenshot], deleted: [])
        let firstRow = cache.row(for: try XCTUnwrap(try database.fetch(id: screenshot.id)))
        let firstSource = try XCTUnwrap(firstRow.imageSource)
        let firstImage = try XCTUnwrap(ImageDownsampler.cachedLoad(source: firstSource, maxPixelSize: 24))
        var replaced = screenshot
        replaced.rawData = try png(width: 40, height: 80)
        try database.applySyncChanges(modified: [replaced], deleted: [])
        let secondRow = cache.row(for: try XCTUnwrap(try database.fetch(id: screenshot.id)))
        let secondSource = try XCTUnwrap(secondRow.imageSource)
        let secondImage = try XCTUnwrap(ImageDownsampler.cachedLoad(source: secondSource, maxPixelSize: 24))
        XCTAssertNotEqual(firstRow, secondRow)
        XCTAssertNotEqual(firstSource, secondSource)
        XCTAssertFalse(firstImage === secondImage)
        XCTAssertTrue(secondImage === ImageDownsampler.cachedLoad(source: secondSource, maxPixelSize: 24))
        XCTAssertEqual(cache.rowBuildCountForTesting, 2)
        XCTAssertEqual(secondImage.representations.first?.pixelsWide, 12)
        XCTAssertEqual(secondImage.representations.first?.pixelsHigh, 24)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(.red, atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
