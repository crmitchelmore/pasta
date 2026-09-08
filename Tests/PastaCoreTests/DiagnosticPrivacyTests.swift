import Foundation
import XCTest
@testable import PastaCore

final class DiagnosticPrivacyTests: XCTestCase {
    func testErrorsDoNotExposeDescriptionsPathsOrCustomDomains() {
        let secret = "clipboard-secret /Users/private/export.json https://private.example/token"
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [
            NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret,
            NSUnderlyingErrorKey: NSError(domain: secret, code: 99)
        ])
        XCTAssertEqual(PastaLogger.diagnosticDescription(error), "NSCocoaErrorDomain code=4")
        XCTAssertEqual(PastaLogger.diagnosticDescription(NSError(domain: secret, code: 42)), "Error code=42")
        let wrapped = PastaError.diskFull(path: secret, underlying: error)
        XCTAssertEqual(PastaLogger.diagnosticDescription(wrapped), "Disk Full (NSCocoaErrorDomain code=4)")
        XCTAssertFalse(PastaLogger.diagnosticDescription(PastaError.unknown(underlying: wrapped)).contains(secret))
        // User-facing errors retain the actionable path locally.
        XCTAssertTrue(wrapped.failureReason?.contains(secret) == true)
    }
}
