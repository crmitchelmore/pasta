import XCTest
@testable import PastaUI

final class ResultCountLabelTests: XCTestCase {
    func testCountsBelowCapAreShownExactly() {
        XCTAssertEqual(SearchBarView.resultCountLabel(0), "0")
        XCTAssertEqual(SearchBarView.resultCountLabel(42), "42")
        XCTAssertEqual(SearchBarView.resultCountLabel(199), "199")
    }

    func testCountsAtOrAboveCapShowPlusSuffix() {
        XCTAssertEqual(SearchBarView.resultCountLabel(200), "200+")
        XCTAssertEqual(SearchBarView.resultCountLabel(500), "200+")
        XCTAssertEqual(SearchBarView.resultCountLabel(10, cap: 10), "10+")
    }
}
