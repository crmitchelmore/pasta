import XCTest

/// End-to-end coverage of the PastaIOS companion app on a simulator with no
/// iCloud account and an empty database. Run with:
///
///     xcodebuild test -project PastaIOS/PastaIOS.xcodeproj -scheme PastaIOS \
///       -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
///       CODE_SIGNING_ALLOWED=NO
///
/// See `PastaIOS/TESTING.md`.
final class PastaIOSUITests: PastaUITestCase {

    // MARK: - Launch

    /// The one test that must catch a launch crash: the process has to reach
    /// the main tab UI and still be in the foreground. A Swift runtime trap
    /// during `AppState.initialise` (database migration, CloudKit, clipboard
    /// capture) terminates the process before the tab bar exists, and XCTest
    /// attaches the crash report to the result bundle.
    func testLaunchesWithoutCrashing() {
        launchApp()
        waitForMainUI()

        // The loading placeholder must have been replaced by real content.
        XCTAssertTrue(
            waitForDisappearance(of: element("loading.view"), timeout: Self.launchTimeout),
            "Loading view is still visible; AppState.initialise never finished"
        )
        XCTAssertTrue(element("history.list").exists, "History list is not the root content after launch")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The app must survive being backgrounded and re-activated, which
    /// re-runs the activation pipeline (sync + clipboard capture).
    func testSurvivesBackgroundAndForeground() {
        launchApp()
        waitForMainUI()

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: Self.uiTimeout),
            "App did not move to the background"
        )

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout), "App did not return to the foreground")
        XCTAssertTrue(tabBar.waitForExistence(timeout: Self.uiTimeout), "Tab bar missing after re-activation")
    }

    // MARK: - Tabs

    func testHistoryTabShowsListAndEmptyState() {
        launchApp()
        waitForMainUI()

        openTab("History", expecting: "history.list")
        XCTAssertTrue(app.navigationBars["Clipboard History"].waitForExistence(timeout: Self.uiTimeout))

        // With an empty database the list shows the empty state unless the
        // simulator pasteboard happened to hold text that was captured.
        let emptyState = element("history.emptyState")
        let firstRow = element("history.row")
        let predicate = NSPredicate { _, _ in emptyState.exists || firstRow.exists }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: Self.uiTimeout),
            .completed,
            "History shows neither the empty state nor any rows"
        )
    }

    func testSearchTabIsReachable() {
        launchApp()
        waitForMainUI()

        openTab("Search", expecting: "search.list")
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(element("search.emptyPrompt").waitForExistence(timeout: Self.uiTimeout))
    }

    func testSettingsTabIsReachable() {
        launchApp()
        waitForMainUI()

        openTab("Settings", expecting: "settings.list")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: Self.uiTimeout))
    }

    func testCanCycleThroughAllTabs() {
        launchApp()
        waitForMainUI()

        openTab("Search", expecting: "search.list")
        openTab("Settings", expecting: "settings.list")
        openTab("History", expecting: "history.list")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Search

    /// Regression for #74: the search field must be visible as soon as the
    /// Search tab opens (`.navigationBarDrawer(displayMode: .always)`), with
    /// no scrolling needed to reveal it.
    func testSearchFieldIsVisibleImmediatelyWithoutScrolling() {
        launchApp()
        waitForMainUI()
        openTab("Search", expecting: "search.list")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout), "Search field never appeared")
        XCTAssertTrue(searchField.isHittable, "Search field exists but is not hittable without scrolling")

        // The field must sit in the navigation-bar drawer at the top of the
        // screen, not off-screen or somewhere the user has to scroll to.
        let window = app.windows.firstMatch.frame
        let field = searchField.frame
        XCTAssertGreaterThan(field.height, 0)
        XCTAssertTrue(window.contains(field), "Search field is off-screen: \(field) not inside \(window)")
        XCTAssertLessThan(
            field.maxY,
            window.minY + window.height * 0.4,
            "Search field is not in the top part of the screen: \(field) in \(window)"
        )
        XCTAssertTrue(element("search.emptyPrompt").exists, "List content missing beneath the search field")
    }

    func testTypingASearchQueryShowsResultsOrEmptyState() {
        launchApp()
        waitForMainUI()
        openTab("Search", expecting: "search.list")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))
        searchField.tap()
        searchField.typeText("zzqx-no-such-entry")

        let noResults = element("search.noResults")
        let firstResult = element("search.row")
        let predicate = NSPredicate { _, _ in noResults.exists || firstResult.exists }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: Self.uiTimeout),
            .completed,
            "Search showed neither results nor the no-results state"
        )
        XCTAssertEqual(app.state, .runningForeground, "App crashed while searching")

        // Clearing the query returns to the idle prompt.
        if app.buttons["Clear text"].exists {
            app.buttons["Clear text"].tap()
        } else {
            searchField.buttons.firstMatch.tap()
        }
        XCTAssertTrue(element("search.emptyPrompt").waitForExistence(timeout: Self.uiTimeout))
    }

    func testSearchFindsACapturedClipboardEntry() {
        let token = "PastaSearchToken\(UUID().uuidString.prefix(8))"
        launchApp(pasteboard: "Searchable clipboard text \(token)")
        waitForMainUI()
        openTab("Search", expecting: "search.list")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))
        searchField.tap()
        searchField.typeText(token)

        let match = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", token)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: Self.uiTimeout), "Search did not return the captured entry")
    }

    // MARK: - Settings

    func testSettingsRendersItsSections() {
        launchApp()
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")

        XCTAssertTrue(app.staticTexts["Sync"].waitForExistence(timeout: Self.uiTimeout), "Sync section header missing")
        XCTAssertTrue(element("settings.iCloudStatus").exists, "iCloud status row missing")
        XCTAssertTrue(element("settings.entryCount").exists, "Entries row missing")
        XCTAssertTrue(app.buttons["Sync Now"].exists, "Sync Now button missing")
        XCTAssertTrue(element("settings.replayWalkthrough").exists, "Replay Walkthrough missing")
        XCTAssertTrue(element("settings.whatsNew").exists, "What's New missing")

        // The About and Reset rows may need a scroll on small simulators.
        let version = element("settings.version")
        if !version.exists {
            app.swipeUp()
        }
        XCTAssertTrue(version.waitForExistence(timeout: Self.uiTimeout), "Version row missing")
        XCTAssertFalse(version.label.isEmpty, "Version row is blank")
        XCTAssertTrue(app.buttons["Reset Sync"].exists, "Reset Sync button missing")

        // Without an iCloud account the status must read Unavailable, never
        // Connected, and the count must reflect the (empty or one-entry) DB.
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Unavailable"))
        XCTAssertNotNil(Int(element("settings.entryCount").label))
    }

    /// The harmless "setting" that round-trips: replaying the walkthrough
    /// presents the onboarding sheet and dismissing it returns to Settings.
    func testReplayWalkthroughRoundTrips() {
        launchApp()
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")

        element("settings.replayWalkthrough").tap()
        let title = element("onboarding.title")
        XCTAssertTrue(title.waitForExistence(timeout: Self.uiTimeout), "Walkthrough sheet did not appear")
        XCTAssertEqual(title.label, "Pasta Walkthrough")

        let done = element("onboarding.primaryButton")
        XCTAssertTrue(done.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(done.label, "Done")
        done.tap()

        XCTAssertTrue(waitForDisappearance(of: title), "Walkthrough sheet did not dismiss")
        XCTAssertTrue(element("settings.list").exists, "Settings list gone after dismissing the walkthrough")
        XCTAssertTrue(tabButton("Settings").isSelected, "Settings tab lost selection after the sheet")
    }

    func testWhatsNewSheetRoundTrips() {
        launchApp()
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")

        element("settings.whatsNew").tap()
        let list = element("whatsNew.list")
        XCTAssertTrue(list.waitForExistence(timeout: Self.uiTimeout), "What's New sheet did not appear")

        element("whatsNew.done").tap()
        XCTAssertTrue(waitForDisappearance(of: list), "What's New sheet did not dismiss")
        XCTAssertTrue(element("settings.list").exists)
    }

    // MARK: - Onboarding

    func testFirstLaunchShowsOnboardingAndGetStartedReachesMainUI() {
        launchApp(skipOnboarding: false)

        let title = element("onboarding.title")
        XCTAssertTrue(title.waitForExistence(timeout: Self.launchTimeout), "Onboarding did not appear on first launch")
        XCTAssertEqual(title.label, "Welcome to Pasta")
        XCTAssertFalse(tabBar.exists, "Tab bar visible while onboarding is showing")

        let getStarted = element("onboarding.primaryButton")
        XCTAssertTrue(getStarted.exists)
        XCTAssertEqual(getStarted.label, "Get Started")
        getStarted.tap()

        waitForMainUI()
        XCTAssertFalse(title.exists, "Onboarding still visible after Get Started")
    }

    func testOnboardingCompletionPersistsAcrossRelaunch() {
        launchApp(skipOnboarding: false)
        let getStarted = element("onboarding.primaryButton")
        XCTAssertTrue(getStarted.waitForExistence(timeout: Self.launchTimeout))
        getStarted.tap()
        waitForMainUI()

        // Relaunch WITHOUT the reset hook: the completed flag must survive.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-uiTesting"]
        relaunched.launchEnvironment["PASTA_UI_TEST_RESET"] = "0"
        relaunched.launchEnvironment["PASTA_UI_TEST_SKIP_ONBOARDING"] = "0"
        relaunched.launch()
        app = relaunched

        waitForMainUI()
        XCTAssertFalse(element("onboarding.title").exists, "Onboarding re-appeared after completing it")
    }

    func testSkipOnboardingHookLandsOnMainUI() {
        launchApp(skipOnboarding: true)
        waitForMainUI()
        XCTAssertFalse(element("onboarding.title").exists, "Onboarding shown despite the skip hook")
        XCTAssertFalse(element("whatsNew.list").exists, "What's New sheet shown on a fresh install")
    }

    // MARK: - Clipboard capture

    /// `AppState.captureCurrentClipboardIfNeeded` runs on activation: the text
    /// on the pasteboard must show up as the newest History entry.
    func testCapturesPasteboardIntoHistoryOnActivation() {
        let token = "PastaClipboard\(UUID().uuidString.prefix(8))"
        let content = "UI test clipboard entry \(token)"
        launchApp(pasteboard: content)
        waitForMainUI()

        openTab("History", expecting: "history.list")
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", token)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.uiTimeout), "Captured clipboard entry not shown in History")
        XCTAssertFalse(element("history.emptyState").exists, "Empty state shown although an entry was captured")

        // The Settings entry count must agree with the list.
        openTab("Settings", expecting: "settings.list")
        let count = Int(element("settings.entryCount").label) ?? -1
        XCTAssertGreaterThanOrEqual(count, 1, "Entry count does not reflect the captured entry")
    }

    /// Tapping the captured entry opens its detail screen and back returns to
    /// the list, exercising the row -> detail navigation path.
    func testOpeningACapturedEntryShowsDetail() {
        let token = "PastaDetail\(UUID().uuidString.prefix(8))"
        launchApp(pasteboard: "Detail view clipboard entry \(token)")
        waitForMainUI()

        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", token)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.uiTimeout))
        row.tap()

        // The detail view shows the full content and a back button.
        let detailBar = app.navigationBars["Entry"]
        XCTAssertTrue(detailBar.waitForExistence(timeout: Self.uiTimeout), "Entry detail screen did not open")
        let detailText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", token))
        XCTAssertTrue(detailText.firstMatch.waitForExistence(timeout: Self.uiTimeout))
        let back = detailBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: Self.uiTimeout), "No back button on the detail screen")
        back.tap()
        XCTAssertTrue(app.navigationBars["Clipboard History"].waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
