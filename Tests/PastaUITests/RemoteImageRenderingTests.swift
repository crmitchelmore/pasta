import AppKit
import PastaCore
import XCTest
@testable import PastaUI

final class RemoteImageRenderingTests: XCTestCase {
    func testDownloadedImageHasThumbnailSourceAndDecodesWithoutLocalFile() throws {
        let database = try DatabaseManager.inMemory()
        let bytes = try png(width: 80, height: 40)
        let remote = ClipboardEntry(content: "remote image", contentType: .image, rawData: bytes)
        try database.applySyncChanges(modified: [remote], deleted: [])

        let stored = try XCTUnwrap(try database.fetch(id: remote.id))
        let row = ClipboardRowData(from: stored)
        XCTAssertNil(row.imagePath)
        XCTAssertTrue(row.prefersImageThumbnail)
        let source = try XCTUnwrap(row.imageSource)
        XCTAssertEqual(source, .data(bytes))

        let image = try XCTUnwrap(ImageDownsampler.cachedLoad(source: source, maxPixelSize: 20))
        let representation = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(representation.pixelsWide, 20)
        XCTAssertEqual(representation.pixelsHigh, 10)
    }

    func testSameRecordImageReplacementInvalidatesRowAndDecodedImage() throws {
        let database = try DatabaseManager.inMemory()
        let first = ClipboardEntry(content: "image", contentType: .screenshot, rawData: try png(width: 80, height: 40))
        let cache = ClipboardRowModelCache()
        try database.applySyncChanges(modified: [first], deleted: [])
        let firstRow = cache.row(for: try XCTUnwrap(try database.fetch(id: first.id)))
        let firstSource = try XCTUnwrap(firstRow.imageSource)
        let firstImage = try XCTUnwrap(ImageDownsampler.cachedLoad(source: firstSource, maxPixelSize: 24))

        var replacement = first
        replacement.rawData = try png(width: 40, height: 80)
        try database.applySyncChanges(modified: [replacement], deleted: [])
        let secondRow = cache.row(for: try XCTUnwrap(try database.fetch(id: first.id)))
        let secondSource = try XCTUnwrap(secondRow.imageSource)
        let secondImage = try XCTUnwrap(ImageDownsampler.cachedLoad(source: secondSource, maxPixelSize: 24))

        XCTAssertNotEqual(firstRow, secondRow)
        XCTAssertNotEqual(firstSource, secondSource)
        XCTAssertFalse(firstImage === secondImage)
        XCTAssertEqual(secondImage.representations.first?.pixelsWide, 12)
        XCTAssertEqual(secondImage.representations.first?.pixelsHigh, 24)
        XCTAssertTrue(secondImage === ImageDownsampler.cachedLoad(source: secondSource, maxPixelSize: 24))
        XCTAssertEqual(cache.rowBuildCountForTesting, 2)
    }

    func testLocalImageUsesFileAndNonImagesDoNotTreatRawDataAsImage() throws {
        let bytes = try png(width: 4, height: 4)
        let local = ClipboardEntry(content: "image", contentType: .image, rawData: bytes, imagePath: "/local/image.png")
        XCTAssertEqual(ClipboardImageSource(entry: local), .file("/local/image.png"))
        XCTAssertNil(ClipboardImageSource(entry: ClipboardEntry(content: "text", contentType: .text, rawData: bytes)))
        XCTAssertNil(ClipboardImageSource(entry: ClipboardEntry(content: "image", contentType: .image)))
        XCTAssertNil(ImageDownsampler.cachedLoad(source: .data(Data([0, 1, 2])), maxPixelSize: 24))
    }

    @MainActor
    func testPreviewEqualityDetectsSameIDSameLengthContentAndAssetChanges() throws {
        let first = ClipboardEntry(content: "first", contentType: .text)
        var replacement = first
        replacement.content = "other"
        XCTAssertNotEqual(PreviewPanelView(entry: first), PreviewPanelView(entry: replacement))

        let image = ClipboardEntry(content: "image", contentType: .image, rawData: try png(width: 4, height: 4))
        var newImage = image
        newImage.rawData = try png(width: 8, height: 4)
        XCTAssertNotEqual(PreviewPanelView(entry: image), PreviewPanelView(entry: newImage))
        XCTAssertEqual(PreviewPanelView(entry: newImage), PreviewPanelView(entry: newImage))
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
