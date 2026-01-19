import XCTest
@testable import PastaCore

final class LaunchAtLoginManagerTests: XCTestCase {
    private final class StubService: LoginItemServicing {
        var isEnabled: Bool
        private(set) var registerCallCount: Int = 0
        private(set) var unregisterCallCount: Int = 0
        var registerError: Error? = nil
        var unregisterError: Error? = nil

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
            if let unregisterError { throw unregisterError }
            isEnabled = false
        }
    }

    private struct TestError: Error {}

    func testSetEnabledTrueRegisters() throws {
        let service = StubService(isEnabled: false)
        let manager = LaunchAtLoginManager(service: service)

        let enabled = try manager.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertTrue(enabled)
        XCTAssertTrue(manager.isEnabled)
    }

    func testSetEnabledFalseUnregisters() throws {
        let service = StubService(isEnabled: true)
        let manager = LaunchAtLoginManager(service: service)

        let enabled = try manager.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(enabled)
        XCTAssertFalse(manager.isEnabled)
    }

    func testSetEnabledPropagatesError() {
        let service = StubService(isEnabled: false)
        service.registerError = TestError()
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(true))
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(service.isEnabled)
    }
}
