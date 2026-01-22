import XCTest
@testable import PastaCore

#if canImport(AppKit) && canImport(ApplicationServices)
final class PasteServiceTests: XCTestCase {
    private final class StubPasteboard: PasteboardWriting {
        private(set) var written: PasteService.Contents?
        var savedContents: PasteService.SavedContents?
        private(set) var restoredContents: PasteService.SavedContents?

        func write(_ contents: PasteService.Contents) {
            written = contents
        }
        
        func saveCurrentContents() -> PasteService.SavedContents? {
            return savedContents
        }
        
        func restore(_ contents: PasteService.SavedContents) {
            restoredContents = contents
        }
    }

    private final class StubSimulator: PasteEventSimulating {
        private(set) var callCount: Int = 0

        func simulateCommandV() {
            callCount += 1
        }
    }

    func testPastesTextAndSimulatesCommandV() {
        let pb = StubPasteboard()
        let sim = StubSimulator()
        let service = PasteService(pasteboard: pb, simulator: sim)

        let entry = ClipboardEntry(content: "hello", contentType: .text)
        XCTAssertTrue(service.paste(entry))
        XCTAssertEqual(pb.written, .text("hello"))
        XCTAssertEqual(sim.callCount, 1)
    }

    func testCopiesTextWithoutSimulatingCommandV() {
        let pb = StubPasteboard()
        let sim = StubSimulator()
        let service = PasteService(pasteboard: pb, simulator: sim)

        let entry = ClipboardEntry(content: "hello", contentType: .text)
        XCTAssertTrue(service.copy(entry))
        XCTAssertEqual(pb.written, .text("hello"))
        XCTAssertEqual(sim.callCount, 0)
    }

    func testPastesFilePathsAsURLs() {
        let pb = StubPasteboard()
        let sim = StubSimulator()
        let service = PasteService(pasteboard: pb, simulator: sim)

        let entry = ClipboardEntry(content: "/tmp/a\n/tmp/b", contentType: .filePath)
        XCTAssertTrue(service.paste(entry))

        guard case .fileURLs(let urls)? = pb.written else {
            return XCTFail("Expected fileURLs")
        }

        XCTAssertEqual(urls.map(\.path), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(sim.callCount, 1)
    }

    func testPastesImageTIFF() {
        let pb = StubPasteboard()
        let sim = StubSimulator()
        let service = PasteService(pasteboard: pb, simulator: sim)

        let data = Data([0x01, 0x02])
        let entry = ClipboardEntry(content: "", contentType: .image, rawData: data)
        XCTAssertTrue(service.paste(entry))
        XCTAssertEqual(pb.written, .imageTIFF(data))
        XCTAssertEqual(sim.callCount, 1)
    }

    func testReturnsFalseWhenImageHasNoData() {
        let pb = StubPasteboard()
        let sim = StubSimulator()
        let service = PasteService(pasteboard: pb, simulator: sim)

        let entry = ClipboardEntry(content: "", contentType: .image, rawData: nil)
        XCTAssertFalse(service.paste(entry))
        XCTAssertNil(pb.written)
        XCTAssertEqual(sim.callCount, 0)
    }
}
#endif
