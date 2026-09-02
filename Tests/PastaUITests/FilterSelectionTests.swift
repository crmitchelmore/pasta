import XCTest
import PastaCore
@testable import PastaUI

final class FilterSelectionTests: XCTestCase {
    func testAllAndPinnedDeriveNoNarrowingFilters() {
        for selection in [FilterSelection.all, .pinned] {
            XCTAssertNil(selection.contentType)
            XCTAssertNil(selection.urlDomain)
            XCTAssertNil(selection.sourceApp)
        }
        XCTAssertFalse(FilterSelection.all.isPinnedOnly)
        XCTAssertTrue(FilterSelection.pinned.isPinnedOnly)
    }

    func testTypeDerivesOnlyContentType() {
        let selection = FilterSelection.type(.email)
        XCTAssertEqual(selection.contentType, .email)
        XCTAssertNil(selection.urlDomain)
        XCTAssertNil(selection.sourceApp)
        XCTAssertFalse(selection.isPinnedOnly)
    }

    func testDomainImpliesURLType() {
        let specific = FilterSelection.domain("github.com")
        XCTAssertEqual(specific.contentType, .url)
        XCTAssertEqual(specific.urlDomain, "github.com")

        // "All Domains" narrows to URLs without a specific domain.
        let allDomains = FilterSelection.domain("")
        XCTAssertEqual(allDomains.contentType, .url)
        XCTAssertNil(allDomains.urlDomain)
    }

    func testSourceAppDerivesOnlySourceApp() {
        let selection = FilterSelection.sourceApp("com.apple.Safari")
        XCTAssertEqual(selection.sourceApp, "com.apple.Safari")
        XCTAssertNil(selection.contentType)
        XCTAssertNil(selection.urlDomain)
        XCTAssertFalse(selection.isPinnedOnly)
    }
}
