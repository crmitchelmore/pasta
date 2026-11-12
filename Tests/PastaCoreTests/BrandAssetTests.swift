#if os(macOS)
import AppKit
import XCTest

final class BrandAssetTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every icon slot has exact pixels and platform alpha, Alpha artwork is distinct
    /// and complete, and the bundle and in-app branding share the same artwork.
    func testBrandArtworkIsCompleteAndConsistent() throws {
        for (folder, expectsAlpha) in [
            ("Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset", true),
            ("PastaIOS/PastaIOS/Assets.xcassets/AppIcon.appiconset", false),
            ("Sources/PastaApp/Resources/Assets.xcassets/AppIconAlpha.appiconset", true),
            ("PastaIOS/PastaIOS/Assets.xcassets/AppIconAlpha.appiconset", false)
        ] {
            let directory = root.appendingPathComponent(folder)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Contents.json"))) as! [String: Any]
            let entries = json["images"] as! [[String: Any]]
            for entry in entries {
                let name = try XCTUnwrap(entry["filename"] as? String)
                let points = Double((entry["size"] as! String).split(separator: "x")[0])!
                let scale = Double((entry["scale"] as? String ?? "1x").dropLast())!
                let pixels = Int((points * scale).rounded())
                let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(name))))
                XCTAssertEqual(image.pixelsWide, pixels, name)
                XCTAssertEqual(image.pixelsHigh, pixels, name)
                XCTAssertEqual(image.hasAlpha, expectsAlpha, name)
                if expectsAlpha {
                    XCTAssertEqual(image.colorAt(x: 0, y: 0)?.alphaComponent, 0, name)
                }
            }
        }
        let alpha = try Data(contentsOf: root.appendingPathComponent("Resources/DMG/AppIconAlpha.icns"))
        let stable = try Data(contentsOf: root.appendingPathComponent("Resources/DMG/AppIcon.icns"))
        XCTAssertNotEqual(alpha, stable)
        let icon = try XCTUnwrap(NSImage(data: alpha))
        XCTAssertTrue(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: Set(icon.representations.map(\.pixelsWide))))

        func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
        XCTAssertEqual(try data("Sources/PastaApp/Resources/AppIcon.png"),
                       try data("Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"))
        // iOS onboarding draws the mark at 96 pt, so it ships at exactly 3x.
        let mark = try XCTUnwrap(NSBitmapImageRep(data: data("PastaIOS/PastaIOS/Assets.xcassets/PastaMark.imageset/PastaMark.png")))
        XCTAssertEqual(mark.pixelsWide, 288)
        XCTAssertEqual(mark.pixelsHigh, 288)
        XCTAssertFalse(mark.hasAlpha)
        let stableIcon = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/DMG/AppIcon.icns")))
        let sizes = Set(stableIcon.representations.map(\.pixelsWide))
        XCTAssertTrue(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes), "Incomplete ICNS: \(sizes)")
    }
}
#endif
