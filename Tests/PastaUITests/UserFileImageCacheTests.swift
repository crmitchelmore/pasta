import AppKit
import XCTest
@testable import PastaUI

final class UserFileImageCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserFileImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testUnchangedUserFileIsServedFromCache() throws {
        let url = directory.appendingPathComponent("photo.png")
        try png(width: 80, height: 40).write(to: url)

        let first = try XCTUnwrap(ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))
        let second = try XCTUnwrap(ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))

        XCTAssertTrue(first === second)
    }

    func testEditedUserFileIsDecodedAgain() throws {
        let url = directory.appendingPathComponent("photo.png")
        try png(width: 80, height: 40).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        let landscape = try XCTUnwrap(ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))

        try png(width: 40, height: 80).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: url.path)
        let portrait = try XCTUnwrap(ImageDownsampler.cachedLoad(userFilePath: url.path, maxPixelSize: 32))

        XCTAssertFalse(landscape === portrait)
        let landscapeRep = try XCTUnwrap(landscape.representations.first)
        let portraitRep = try XCTUnwrap(portrait.representations.first)
        XCTAssertGreaterThan(landscapeRep.pixelsWide, landscapeRep.pixelsHigh)
        XCTAssertGreaterThan(portraitRep.pixelsHigh, portraitRep.pixelsWide)
    }

    func testMissingUserFileReturnsNil() {
        let path = directory.appendingPathComponent("missing.png").path
        XCTAssertNil(ImageDownsampler.cachedLoad(userFilePath: path, maxPixelSize: 32))
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
