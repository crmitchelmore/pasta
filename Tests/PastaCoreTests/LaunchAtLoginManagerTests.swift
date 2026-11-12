import XCTest
@testable import PastaCore

final class LaunchAtLoginManagerTests: XCTestCase {
    private final class StubService: LoginItemServicing {
        var isEnabled: Bool
        private(set) var registerCallCount = 0
        private(set) var unregisterCallCount = 0
        var registerError: Error?

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }

        func register() throws {
            registerCallCount += 1
            if let registerError { throw registerError }
            isEnabled = true
        }

        func unregister() throws {
            unregisterCallCount += 1
            isEnabled = false
        }
    }

    private struct TestError: Error {}

    func testSetEnabledRegistersUnregistersAndPropagatesFailure() throws {
        let service = StubService(isEnabled: false)
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertTrue(try manager.setEnabled(true))
        XCTAssertTrue(manager.isEnabled)
        XCTAssertFalse(try manager.setEnabled(false))
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 1)

        service.registerError = TestError()
        XCTAssertThrowsError(try manager.setEnabled(true))
        XCTAssertFalse(service.isEnabled)
    }
}
