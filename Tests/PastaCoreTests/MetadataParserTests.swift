import XCTest
@testable import PastaCore

final class MetadataParserTests: XCTestCase {
    func testExtractAllValuesIncludesCustomDetectors() {
        let metadata = """
        {
          "emails":[{"email":"user@example.com","confidence":0.9}],
          "customDetectors":[
            {"name":"Ticket ID","value":"4821","confidence":0.8},
            {"name":"Order Ref","value":"ORD-123","confidence":0.75}
          ]
        }
        """

        let values = MetadataParser.extractAllValues(from: metadata)
        XCTAssertTrue(values.contains(where: { $0.type == .email && $0.value == "user@example.com" }))
        XCTAssertTrue(values.contains(where: { $0.type == .text && $0.displayValue == "Ticket ID: 4821" }))
        XCTAssertTrue(values.contains(where: { $0.type == .text && $0.displayValue == "Order Ref: ORD-123" }))
    }
}
