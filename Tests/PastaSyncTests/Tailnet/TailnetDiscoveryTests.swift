#if os(macOS)
import XCTest
@testable import PastaSync

final class TailnetDiscoveryTests: XCTestCase {
    func testParsesVisibleMacsAndFailsClosedWhenDisconnected() throws {
        let json = """
        {"BackendState":"Running","Self":{"ID":"me","HostName":"my-mac","TailscaleIPs":["fd7a::1","100.64.1.1"]},
        "Peer":{"key1":{"ID":"other","HostName":"other-mac","OS":"macOS","Online":true,"TailscaleIPs":["100.64.1.2"]},
        "key2":{"ID":"phone","HostName":"iphone","OS":"iOS","Online":true,"TailscaleIPs":["100.64.1.3"]}}}
        """
        let inventory = try TailnetInventory.parse(Data(json.utf8))
        XCTAssertEqual(inventory.local.id, "me")
        XCTAssertEqual(inventory.local.address, "100.64.1.1")
        XCTAssertEqual(inventory.peers.map(\.id), ["other"])
        XCTAssertThrowsError(try TailnetInventory.parse(Data(json.replacingOccurrences(of: "Running", with: "Stopped").utf8)))
    }
    func testTailnetAddressBoundaryRejectsLANAndLookalikeAddresses() {
        for address in ["100.64.0.1", "100.127.255.254"] { XCTAssertTrue(TailnetInventory.isTailnetIPv4(address)) }
        for address in ["100.63.255.255", "100.128.0.1", "192.168.1.1", "127.0.0.1", "100.64.0.256", "100.64.0.1.evil", "localhost"] { XCTAssertFalse(TailnetInventory.isTailnetIPv4(address)) }
    }
    func testRandomPairingTokensAreStrongAndComparisonFailsClosed() throws {
        let a = try TailnetKeychain.token(), b = try TailnetKeychain.token()
        XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(TailnetKeychain.matches(a, a))
        XCTAssertFalse(TailnetKeychain.matches(a, b))
        XCTAssertFalse(TailnetKeychain.matches(nil, nil))
    }
}
#endif
