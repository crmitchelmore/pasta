import XCTest
@testable import PastaDetectors

final class PastaDetectorsTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(PastaDetectors.version, "0.1.0")
    }
}
