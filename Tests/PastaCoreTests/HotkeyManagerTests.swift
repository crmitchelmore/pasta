import XCTest
@testable import PastaCore

#if canImport(AppKit)
import AppKit
import KeyboardShortcuts

final class HotkeyManagerTests: XCTestCase {
    func testHotkeyManagerInitializesSuccessfully() {
        var fired = false
        let manager = HotkeyManager {
            fired = true
        }
        // Keep manager alive
        _ = manager
        
        // Verify the shortcut name is registered
        XCTAssertNotNil(KeyboardShortcuts.Name.openPasta)
        
        // Note: We can't easily simulate KeyboardShortcuts triggering in tests
        // The library handles global key registration internally
        XCTAssertFalse(fired, "Handler should not fire without actual key press")
    }
    
    func testReloadFromUserDefaultsDoesNotCrash() {
        let manager = HotkeyManager {
            // Empty handler
        }
        
        // Should not throw
        manager.reloadFromUserDefaults()
    }
}
#endif
