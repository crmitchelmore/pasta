import XCTest

/// Shared launch helpers for the PastaIOS end-to-end suite.
///
/// Every launch passes `-uiTesting` plus `PASTA_UI_TEST_RESET=1`, so the app
/// starts from an empty database and cleared UserDefaults. Tests opt in to the
/// other hooks (`skipOnboarding`, `pasteboard`) per launch. The hooks are
/// documented in `PastaIOS/TESTING.md` and implemented in
/// `PastaIOS/PastaIOS/Services/UITestConfiguration.swift`.
class PastaUITestCase: XCTestCase {
    /// How long the root UI may take to appear after launch. Generous because a
    /// cold simulator on a CI runner is slow; a crash fails much sooner.
    static let launchTimeout: TimeInterval = 15
    static let uiTimeout: TimeInterval = 8

    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
        try super.tearDownWithError()
    }

    // MARK: - Launching

    /// Launches the app with the UI-test hooks applied.
    /// - Parameters:
    ///   - skipOnboarding: land directly on the main tab UI (default) or on
    ///     the first-run onboarding screen.
    ///   - pasteboard: string the app writes to `UIPasteboard.general` before
    ///     its activation-time clipboard capture runs.
    @discardableResult
    func launchApp(skipOnboarding: Bool = true, pasteboard: String? = nil) -> XCUIApplication {
        app.launchArguments += ["-uiTesting"]
        app.launchEnvironment["PASTA_UI_TEST_RESET"] = "1"
        app.launchEnvironment["PASTA_UI_TEST_SKIP_ONBOARDING"] = skipOnboarding ? "1" : "0"
        if let pasteboard {
            app.launchEnvironment["PASTA_UI_TEST_PASTEBOARD"] = pasteboard
        }
        app.launch()
        return app
    }

    // MARK: - Queries

    /// Any element carrying the given accessibility identifier, regardless of
    /// the element type SwiftUI chose for it on this OS version.
    func element(_ identifier: String) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: identifier)
        if buttons.count > 0 { return buttons.firstMatch }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    var tabBar: XCUIElement { app.tabBars.firstMatch }

    func tabButton(_ title: String) -> XCUIElement {
        tabBar.buttons[title]
    }

    // MARK: - Assertions

    /// Waits for the main tab UI to appear and asserts the process is still in
    /// the foreground. Fails fast with the app's state if it terminated.
    func waitForMainUI(file: StaticString = #filePath, line: UInt = #line) {
        let appeared = tabBar.waitForExistence(timeout: Self.launchTimeout)
        XCTAssertTrue(
            appeared,
            "Main tab bar did not appear within \(Self.launchTimeout)s (app state: \(app.state.rawValue))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "App is not running in the foreground after launch (state: \(app.state.rawValue))",
            file: file,
            line: line
        )
    }

    /// Selects a tab and waits for the element that proves it rendered.
    func openTab(_ title: String, expecting identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = tabButton(title)
        XCTAssertTrue(button.waitForExistence(timeout: Self.uiTimeout), "Tab '\(title)' not found", file: file, line: line)
        button.tap()
        XCTAssertTrue(
            element(identifier).waitForExistence(timeout: Self.uiTimeout),
            "Tab '\(title)' did not show '\(identifier)'",
            file: file,
            line: line
        )
        XCTAssertTrue(button.isSelected, "Tab '\(title)' is not selected after tapping it", file: file, line: line)
    }

    /// Polls until the element disappears (or the timeout elapses).
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = uiTimeout) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
