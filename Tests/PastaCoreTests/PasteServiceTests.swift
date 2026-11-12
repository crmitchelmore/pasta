import XCTest
@testable import PastaCore

#if canImport(AppKit) && canImport(ApplicationServices)
final class PasteServiceTests: XCTestCase {
    private final class StubPasteboard: PasteboardWriting {
        private(set) var written: PasteService.Contents?

        func write(_ contents: PasteService.Contents) {
            written = contents
        }

        func saveCurrentContents() -> PasteService.SavedContents? { nil }

        func restore(_ contents: PasteService.SavedContents) {}
    }

    private final class StubSimulator: PasteEventSimulating {
        private(set) var callCount = 0

        func simulateCommandV() {
            callCount += 1
        }
    }

    private enum Operation {
        case paste, pastePlainText, copy, copyJoined
    }

    /// Paste safety: what lands on the pasteboard per content type, Cmd+V only
    /// when trusted and pasting, and nothing written for unrepresentable entries.
    func testPasteAndCopyWriteTheRightRepresentation() {
        let text = ClipboardEntry(content: "hello", contentType: .text)
        let world = ClipboardEntry(content: "world", contentType: .text)
        let files = ClipboardEntry(content: "/tmp/a\n/tmp/b", contentType: .filePath)
        let fileURLs = PasteService.Contents.fileURLs([URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")])
        let imageData = Data([0x01, 0x02])
        let image = ClipboardEntry(content: "", contentType: .image, rawData: imageData)
        let emptyImage = ClipboardEntry(content: "", contentType: .image, rawData: nil)

        let cases: [(name: String, operation: Operation, entries: [ClipboardEntry], trusted: Bool,
                     succeeds: Bool, written: PasteService.Contents?, commandV: Int)] = [
            ("paste text", .paste, [text], true, true, .text("hello"), 1),
            ("untrusted paste only copies", .paste, [text], false, true, .text("hello"), 0),
            ("paste file paths as URLs", .paste, [files], true, true, fileURLs, 1),
            ("paste image TIFF", .paste, [image], true, true, .imageTIFF(imageData), 1),
            ("image without data", .paste, [emptyImage], true, false, nil, 0),
            ("plain text of file paths", .pastePlainText, [files], true, true, .text("/tmp/a\n/tmp/b"), 1),
            ("plain text of image", .pastePlainText, [image], true, false, nil, 0),
            ("copy text", .copy, [text], true, true, .text("hello"), 0),
            ("copy joined", .copyJoined, [text, world], true, true, .text("hello\nworld"), 0),
            ("single selection keeps type", .copyJoined, [files], true, true, fileURLs, 0),
            ("empty selection", .copyJoined, [], true, false, nil, 0)
        ]

        for testCase in cases {
            let pasteboard = StubPasteboard()
            let simulator = StubSimulator()
            let service = PasteService(pasteboard: pasteboard, simulator: simulator,
                                       isAccessibilityTrusted: { testCase.trusted })
            let result: Bool
            switch testCase.operation {
            case .paste: result = service.paste(testCase.entries[0])
            case .pastePlainText: result = service.pastePlainText(testCase.entries[0])
            case .copy: result = service.copy(testCase.entries[0])
            case .copyJoined: result = service.copy(testCase.entries, joinedBy: "\n")
            }
            XCTAssertEqual(result, testCase.succeeds, "case \(testCase.name)")
            XCTAssertEqual(pasteboard.written, testCase.written, "case \(testCase.name)")
            XCTAssertEqual(simulator.callCount, testCase.commandV, "case \(testCase.name)")
        }
    }
}
#endif
