import XCTest
@testable import PastaCore

final class PastaCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(PastaCore.version, "0.1.0")
    }
}
