#if os(macOS)
import XCTest
import Network
@testable import PastaSync

final class TailnetTransportTests: XCTestCase {
    func testTailnetBoundaryAuthAndFramingFailClosed() async throws {
        do {
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
        do {
            for address in ["100.64.0.1", "100.127.255.254"] { XCTAssertTrue(TailnetInventory.isTailnetIPv4(address)) }
            for address in ["100.63.255.255", "100.128.0.1", "192.168.1.1", "127.0.0.1", "100.64.0.256", "100.64.0.1.evil", "localhost"] { XCTAssertFalse(TailnetInventory.isTailnetIPv4(address)) }
        }
        do {
            let a = try TailnetKeychain.token(), b = try TailnetKeychain.token()
            XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
            XCTAssertNotEqual(a, b)
            XCTAssertTrue(TailnetKeychain.matches(a, a))
            XCTAssertFalse(TailnetKeychain.matches(a, b))
            XCTAssertFalse(TailnetKeychain.matches(nil, nil))
        }
        do {
            let server = TailnetTransport()
            do {
                _ = try await server.listen(address: "192.168.1.1") { _, _ in TailnetResponse(status: "wrong") }
                XCTFail("LAN listener must be rejected")
            } catch { XCTAssertTrue(error is TailnetError) }
        }
        do {
            let server = TailnetTransport()
            defer { server.stop() }
            let port = try await server.listen(address: "127.0.0.1", port: 0) { address, request in
                TailnetResponse(status: request.operation == .hello && address == "127.0.0.1" ? "hello" : "wrong")
            }
            let response = try await TailnetTransport.request(TailnetRequest(operation: .hello), address: "127.0.0.1", port: port)
            XCTAssertEqual(response.status, "hello")
            let again = try await TailnetTransport.request(TailnetRequest(operation: .hello), address: "127.0.0.1", port: port)
            XCTAssertEqual(again.status, "hello")
        }
        do {
            actor Calls { var count = 0; func hit() { count += 1 } }
            let calls = Calls()
            let server = TailnetTransport(); defer { server.stop() }
            let port = try await server.listen(address: "127.0.0.1", port: 0) { _, _ in
                await calls.hit(); return TailnetResponse(status: "bad")
            }
            for bytes in [Data([255, 255, 255, 255]), Data([0, 0, 0, 30, 1, 2, 3])] {
                let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                connection.start(queue: DispatchQueue(label: "malformed-frame"))
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
                do { _ = try await TailnetTransport.readFrame(connection); XCTFail("Malformed request must close the connection") } catch {}
                connection.cancel()
            }
            let count = await calls.count
            XCTAssertEqual(count, 0)
        }
    }
}
#endif
