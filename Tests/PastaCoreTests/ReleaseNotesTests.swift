import Foundation
import XCTest
@testable import PastaCore

final class ReleaseNotesTests: XCTestCase {
    private func catalog() throws -> ReleaseNotesCatalog {
        try JSONDecoder().decode(ReleaseNotesCatalog.self, from: Data("""
        {"entries":[
          {"version":"1.5.18","build":"140","date":"","summary":"Build 140","changes":["Fix A"],"source":""},
          {"version":"1.5.18","build":"141","date":"","summary":"Build 141","changes":["Fix B"],"source":""},
          {"version":"1.5.18","date":"","summary":"Version notes","changes":["Fix C"],"source":""},
          {"version":"1.5.9","date":"","summary":"Old notes","changes":["Fix D"],"source":""},
          {"version":"1.5.19","date":"","summary":"Future","changes":["Fix E"],"source":""}
        ]}
        """.utf8))
    }

    func testExactBuildWinsAndHistoryIsNumericWithoutFutureChanges() throws {
        let notes = try catalog()
        XCTAssertEqual(notes.entry(version: "1.5.18", build: "140")?.summary, "Build 140")
        XCTAssertEqual(notes.entry(version: "1.5.18", build: "142")?.summary, "Version notes")
        XCTAssertNil(notes.entry(version: "1.5.20", build: "142"))
        XCTAssertEqual(notes.history(version: "1.5.18", build: "140").map(\.id), ["1.5.18:version", "1.5.9:version"])
    }

    func testAnotherBuildIsNeverSubstitutedForTheInstalledBuild() throws {
        let notes = ReleaseNotesCatalog(entries: try catalog().entries.filter { $0.build != nil })
        XCTAssertNil(notes.entry(version: "1.5.18", build: "142"))
    }

    func testBundledHistoryIsAvailableOffline() {
        XCTAssertEqual(ReleaseNotesCatalog.bundled.entry(version: "1.5.18", build: "999")?.summary,
                       "More reliable clipboard history shared from your Mac.")
        XCTAssertNil(ReleaseNotesCatalog.bundled.entry(version: "1.5.15", build: "1"))
    }

    func testFreshInstallWaitsForOnboardingAndUpgradeRequiresAcknowledgement() {
        XCTAssertFalse(ReleaseNotesPresentation.shouldPresent(onboardingCompleted: false, acknowledged: nil, version: "1.5.18", build: "140"))
        // Missing new key includes legacy installs whose old version-only key
        // was written even though the sheet never appeared.
        XCTAssertTrue(ReleaseNotesPresentation.shouldPresent(onboardingCompleted: true, acknowledged: nil, version: "1.5.18", build: "140"))
        let seen = ReleaseNotesPresentation.identity(version: "1.5.18", build: "140")
        XCTAssertFalse(ReleaseNotesPresentation.shouldPresent(onboardingCompleted: true, acknowledged: seen, version: "1.5.18", build: "140"))
        XCTAssertTrue(ReleaseNotesPresentation.shouldPresent(onboardingCompleted: true, acknowledged: seen, version: "1.5.18", build: "141"))
        XCTAssertTrue(ReleaseNotesPresentation.shouldPresent(onboardingCompleted: true, acknowledged: seen, version: "1.5.19", build: "142"))
    }
}
