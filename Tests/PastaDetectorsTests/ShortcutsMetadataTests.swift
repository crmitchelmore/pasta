import Foundation
import XCTest

/// App Store review rejects intent metadata naming platforms, devices or the
/// voice assistant (ITMS-90626), so the iOS Shortcuts source must avoid them.
final class ShortcutsMetadataTests: XCTestCase {
    func testShortcutsSourceAvoidsReservedNames() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let intents = repoRoot.appendingPathComponent("PastaIOS/PastaIOS/Intents", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: intents, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "expected Shortcuts sources in \(intents.path)")

        let reserved = ["iPhone", "iPad", "Siri", "Apple"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for word in reserved {
                // Whole words only: `ipAddress` is not the tablet.
                XCTAssertNil(source.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]),
                             "\(file.lastPathComponent) mentions \(word)")
            }
            XCTAssertTrue(source.contains("\\(.applicationName)"), "phrases must name the app")
        }
    }
}
