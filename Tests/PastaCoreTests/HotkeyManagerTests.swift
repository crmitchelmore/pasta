import XCTest
@testable import PastaCore

#if canImport(AppKit) && canImport(HotKey)
import AppKit
import HotKey

final class HotkeyManagerTests: XCTestCase {
    private final class StubHotKey: HotKeyProtocol {
        var keyDownHandler: (() -> Void)?
    }

    private final class CapturingProvider: HotKeyProviding {
        let hotKey: StubHotKey
        private(set) var receivedKey: Key?
        private(set) var receivedModifiers: NSEvent.ModifierFlags?

        init(hotKey: StubHotKey) {
            self.hotKey = hotKey
        }

        func makeHotKey(key: Key, modifiers: NSEvent.ModifierFlags) -> HotKeyProtocol {
            receivedKey = key
            receivedModifiers = modifiers
            return hotKey
        }
    }

    func testRegistersControlCommandCAndFiresHandler() {
        let stubHotKey = StubHotKey()
        let provider = CapturingProvider(hotKey: stubHotKey)

        var fired = false
        _ = HotkeyManager(provider: provider) {
            fired = true
        }

        XCTAssertEqual(provider.receivedKey, .c)
        XCTAssertEqual(provider.receivedModifiers, [.control, .command])

        stubHotKey.keyDownHandler?()
        XCTAssertTrue(fired)
    }
}
#endif
