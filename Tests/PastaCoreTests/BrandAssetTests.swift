#if os(macOS)
import AppKit
import XCTest

final class BrandAssetTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryAppIconSlotHasTheExactPixelsAndPlatformAlpha() throws {
        for (folder, expectsAlpha) in [
            ("Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset", true),
            ("PastaIOS/PastaIOS/Assets.xcassets/AppIcon.appiconset", false)
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
    }

    func testBundleAndInAppBrandingUseTheSameArtwork() throws {
        func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
        XCTAssertEqual(try data("Sources/PastaApp/Resources/AppIcon.png"),
                       try data("Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"))
        XCTAssertEqual(try data("PastaIOS/PastaIOS/Assets.xcassets/PastaMark.imageset/PastaMark.png"),
                       try data("PastaIOS/PastaIOS/Assets.xcassets/AppIcon.appiconset/icon_1024.png"))
        let icon = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/DMG/AppIcon.icns")))
        let sizes = Set(icon.representations.map(\.pixelsWide))
        XCTAssertTrue(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes), "Incomplete ICNS: \(sizes)")
    }
}
#endif
