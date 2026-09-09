#if os(macOS)
import XCTest
import Network
@testable import PastaSync

final class TailnetTransportTests: XCTestCase {
    func testActualTCPFramingAndBindingWithIndependentConnections() async throws {
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
    func testListenerRefusesNonTailnetLANAddress() async throws {
        let server = TailnetTransport()
        do {
            _ = try await server.listen(address: "192.168.1.1") { _, _ in TailnetResponse(status: "wrong") }
            XCTFail("LAN listener must be rejected")
        } catch { XCTAssertTrue(error is TailnetError) }
    }
    func testOversizedAndTruncatedFramesNeverReachRequestHandler() async throws {
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
#endif
