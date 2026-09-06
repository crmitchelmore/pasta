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

        XCTAssertTrue(element("history.emptyState").waitForExistence(timeout: Self.uiTimeout))
        XCTAssertFalse(element("history.row").exists, "Fresh install unexpectedly contains history")
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "0")
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

    func testSearchExcludesNonmatchingEntriesAndClearsToPrompt() {
        let token = "PastaSearchKnown\(UUID().uuidString.prefix(8))"
        launchApp(pasteboard: "Known clipboard content \(token)")
        waitForMainUI()
        openTab("Search", expecting: "search.list")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))
        searchField.tap()
        searchField.typeText(token)
        XCTAssertTrue(element("search.row").waitForExistence(timeout: Self.uiTimeout), "Known query must return the captured entry first")

        // Start from a populated result set so the no-results assertion cannot
        // pass against the initial empty UI before the async search completes.
        searchField.typeText(" zzqxnosuchentry\(UUID().uuidString.prefix(8))")
        XCTAssertTrue(element("search.noResults").waitForExistence(timeout: Self.uiTimeout), "Unmatched query must show no results")
        XCTAssertTrue(waitForDisappearance(of: element("search.row")), "Search retained an unrelated result")
        XCTAssertEqual(app.state, .runningForeground)

        searchField.buttons.firstMatch.tap()
        XCTAssertTrue(element("search.emptyPrompt").waitForExistence(timeout: Self.uiTimeout))
        XCTAssertFalse(element("search.row").exists)
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

    /// Tap the native switch, not the text/container SwiftUI also exposes.
    /// Verify the visible state before testing persistence or starting a retry.
    private func setSyncConsent(_ enabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.switches["settings.iCloudConsent"].firstMatch
        revealSettingsRow(control, scrollUp: false)
        XCTAssertTrue(control.waitForExistence(timeout: Self.uiTimeout), "Sync consent switch missing", file: file, line: line)
        XCTAssertTrue(control.isHittable, "Sync consent switch is not reachable", file: file, line: line)
        XCTAssertEqual(control.value as? String, enabled ? "0" : "1", "Journey must start in the opposite consent state", file: file, line: line)
        // SwiftUI may give the switch a full-row frame including its label.
        // The trailing edge is the actual switch thumb on this English UI.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: control
        )
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: Self.uiTimeout), .completed,
                       "Tapping consent must visibly change the switch", file: file, line: line)
    }

    private func revealSettingsRow(_ row: XCUIElement, scrollUp: Bool = true) {
        let list = element("settings.list")
        for _ in 0..<5 {
            if row.exists && row.isHittable { return }
            if scrollUp { list.swipeUp() } else { list.swipeDown() }
        }
    }


    func testSyncConsentIsExplicitAndWithdrawalPersistsWithoutDeletingHistory() {
        launchApp(pasteboard: "Private until consent")
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Off"))
        XCTAssertFalse(element("settings.syncNow").isEnabled)
        XCTAssertTrue(element("settings.iCloudConsentExplanation").exists)
        XCTAssertEqual(element("settings.entryCount").label, "1")
        setSyncConsent(true)
        app.terminate()
        launchApp(resetState: false)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(app.switches["settings.iCloudConsent"].firstMatch.value as? String, "1")
        setSyncConsent(false)
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Off"))
        XCTAssertFalse(element("settings.syncNow").isEnabled)
        app.terminate()
        launchApp(resetState: false)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(app.switches["settings.iCloudConsent"].firstMatch.value as? String, "0")
        XCTAssertEqual(element("settings.entryCount").label, "1")
    }

    func testUnavailableSyncRetryPreservesOfflineHistory() {
        let token = "OfflineRecovery\(UUID().uuidString.prefix(8))"
        launchApp(pasteboard: token)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        XCTAssertTrue(element("settings.iCloudGuidance").waitForExistence(timeout: Self.uiTimeout),
                      "Unavailable iCloud must explain how to recover")
        XCTAssertEqual(element("settings.entryCount").label, "1")
        XCTAssertFalse(element("settings.syncNow").isEnabled, "Sync requires explicit consent")
        setSyncConsent(true)
        let syncNow = element("settings.syncNow")
        revealSettingsRow(syncNow)
        let accountCheckFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: syncNow
        )
        XCTAssertEqual(XCTWaiter().wait(for: [accountCheckFinished], timeout: Self.uiTimeout), .completed)
        syncNow.tap()
        let retryFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element("settings.syncNow")
        )
        XCTAssertEqual(XCTWaiter().wait(for: [retryFinished], timeout: Self.uiTimeout), .completed)
        let failure = element("settings.syncError")
        XCTAssertTrue(failure.waitForExistence(timeout: Self.uiTimeout), "Failed retry must give a visible next action")
        XCTAssertTrue(failure.label.contains("update"), "The unprovisioned simulator must explain which action to take")
        XCTAssertFalse(failure.label.contains("Sync complete"))
        revealSettingsRow(element("settings.entryCount"))
        XCTAssertEqual(element("settings.entryCount").label, "1", "Retry must retain offline clipboard history")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.uiTimeout))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout))
        openTab("History", expecting: "history.list")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", token))
            .firstMatch.waitForExistence(timeout: Self.uiTimeout))

        app.terminate()
        launchApp(resetState: false)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "1", "Offline history must survive relaunch after retries")
    }

    func testResetExplainsItsEffectAndReportsResultWithoutDeletingOfflineHistory() {
        let content = "Keep this history after reset"
        launchApp(pasteboard: content)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        let reset = element("settings.resetSync")
        revealSettingsRow(reset)
        reset.tap()
        let confirmation = app.alerts["Reset iCloud Sync?"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(confirmation.staticTexts[
            "Your local history and iCloud data are kept. Pasta will download iCloud history again when sync is enabled and connected."
        ].exists)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: confirmation))
        XCTAssertFalse(element("settings.syncFeedback").exists, "Cancelling must not claim a reset")

        reset.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.uiTimeout))
        confirmation.buttons["Reset Sync"].tap()
        XCTAssertTrue(waitForDisappearance(of: confirmation))
        let feedback = element("settings.syncFeedback")
        revealSettingsRow(feedback, scrollUp: false)
        XCTAssertTrue(feedback.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(feedback.label, "Sync reset. Local history kept. Enable iCloud Sync to download your history again.")
        XCTAssertFalse(feedback.label.contains("Sync complete"), "A local-only reset is not a successful cloud sync")
        revealSettingsRow(element("settings.entryCount"))
        XCTAssertEqual(element("settings.entryCount").label, "1")

        app.terminate()
        launchApp(resetState: false)
        waitForMainUI()
        openTab("History", expecting: "history.list")
        XCTAssertTrue(app.staticTexts[content].firstMatch.waitForExistence(timeout: Self.uiTimeout), "Reset must keep persisted clipboard history")
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(app.switches["settings.iCloudConsent"].firstMatch.value as? String, "0", "Reset must not grant sync consent")
    }

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

        // Each row must be brought into view independently on small screens.
        let reset = element("settings.resetSync")
        revealSettingsRow(reset, scrollUp: false)
        XCTAssertTrue(reset.exists, "Reset Sync button missing")
        XCTAssertTrue(reset.isHittable, "Reset Sync must be reachable by scrolling")
        let version = element("settings.version")
        revealSettingsRow(version)
        XCTAssertTrue(version.waitForExistence(timeout: Self.uiTimeout), "Version row missing")
        XCTAssertFalse(version.label.isEmpty, "Version row is blank")

        // Completed onboarding is not permission to upload clipboard history.
        revealSettingsRow(element("settings.iCloudStatus"), scrollUp: false)
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Off"))
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
        if !done.isHittable { app.swipeUp() }
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

        // A toolbar Button surfaces its identifier on both the toolbar item and
        // the button, so narrow to the button type and take the first match.
        let done = app.buttons["whatsNew.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: Self.uiTimeout), "Done button missing on What's New")
        done.tap()
        XCTAssertTrue(waitForDisappearance(of: list), "What's New sheet did not dismiss")
        XCTAssertTrue(element("settings.list").exists)
    }

    // Release-note journeys use real persisted defaults and bundled history.
    // Version/build overrides avoid coupling tests to CI's archive numbering.
    func testReleaseNotesUpgradeAcknowledgesOnlyAfterDismissalAndReplays() {
        app.launchEnvironment["PASTA_UI_TEST_VERSION"] = "1.5.18"
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "140"
        app.launchEnvironment["PASTA_UI_TEST_PREVIOUS_VERSION"] = "1.5.17"
        launchApp(skipOnboarding: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        XCTAssertEqual(element("whatsNew.installedVersion").label, "Version 1.5.18 (140)")
        XCTAssertEqual(element("whatsNew.summary").label, "More reliable clipboard history shared from your Mac.")

        // Killing the app with notes still open must not consume the update.
        app.terminate()
        app.launchEnvironment["PASTA_UI_TEST_PREVIOUS_VERSION"] = nil
        launchApp(skipOnboarding: false, resetState: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        app.buttons["whatsNew.done"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: element("whatsNew.list")))
        app.terminate()
        launchApp(skipOnboarding: false, resetState: false)
        waitForMainUI()
        XCTAssertFalse(element("whatsNew.list").exists)

        openTab("Settings", expecting: "settings.list")
        element("settings.whatsNew").tap()
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.uiTimeout))
        let earlier = element("whatsNew.history.1.5.17:version")
        if !earlier.isHittable { element("whatsNew.list").swipeUp() }
        earlier.tap()
        XCTAssertTrue(element("whatsNew.detail").waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(element("whatsNew.summary").label, "More private diagnostics.")
    }

    func testSameMarketingVersionNewBuildPresentsAndSwipeDismissalPersists() {
        app.launchEnvironment["PASTA_UI_TEST_VERSION"] = "1.5.18"
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "140"
        launchApp()
        waitForMainUI()
        app.terminate()
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "141"
        launchApp(skipOnboarding: false, resetState: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        XCTAssertEqual(element("whatsNew.installedVersion").label, "Version 1.5.18 (141)")
        // Drag from the navigation bar so the sheet dismisses, not the list.
        let bar = app.navigationBars["What’s New"].firstMatch
        bar.swipeDown()
        XCTAssertTrue(waitForDisappearance(of: element("whatsNew.list")))
        app.terminate()
        launchApp(skipOnboarding: false, resetState: false)
        waitForMainUI()
        XCTAssertFalse(element("whatsNew.list").exists)
    }

    func testMissingInstalledNotesAreExplicitAndNeverRelabelOlderCopy() {
        app.launchEnvironment["PASTA_UI_TEST_VERSION"] = "9.0.0"
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "999"
        app.launchEnvironment["PASTA_UI_TEST_PREVIOUS_VERSION"] = "1.5.18"
        launchApp(skipOnboarding: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        XCTAssertEqual(element("whatsNew.installedVersion").label, "Version 9.0.0 (999)")
        XCTAssertTrue(element("whatsNew.unavailable").exists)
        XCTAssertFalse(element("whatsNew.summary").exists)
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
        XCTAssertEqual(getStarted.label, "Continue on This iPhone")
        if !getStarted.isHittable { app.swipeUp() }
        getStarted.tap()

        waitForMainUI()
        XCTAssertFalse(title.exists, "Onboarding still visible after Get Started")
    }

    func testOnboardingCompletionPersistsAcrossRelaunch() {
        launchApp(skipOnboarding: false)
        let getStarted = element("onboarding.primaryButton")
        XCTAssertTrue(getStarted.waitForExistence(timeout: Self.launchTimeout))
        if !getStarted.isHittable { app.swipeUp() }
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
        XCTAssertEqual(count, 1, "One clipboard capture must produce exactly one stored entry")
    }

    /// Relaunch with unrelated clipboard content: the first entry can only
    /// survive via the app's on-disk database, not by recapturing the fixture.
    func testCapturedHistoryPersistsAndRemainsSearchableAfterRelaunch() {
        let token = "PastaPersisted\(UUID().uuidString.prefix(8))"
        let content = "Persisted clipboard content \(token)"
        launchApp(pasteboard: content)
        waitForMainUI()
        XCTAssertTrue(app.staticTexts[content].waitForExistence(timeout: Self.uiTimeout))

        app.terminate()
        app = XCUIApplication()
        launchApp(pasteboard: "Unrelated clipboard replacement", resetState: false)
        waitForMainUI()
        XCTAssertTrue(app.staticTexts[content].waitForExistence(timeout: Self.uiTimeout), "Captured history was lost across relaunch")

        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "2", "Relaunch must retain the first entry and capture the replacement once")
        openTab("Search", expecting: "search.list")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))
        searchField.tap()
        searchField.typeText(token)
        let match = app.staticTexts[content]
        XCTAssertTrue(match.waitForExistence(timeout: Self.uiTimeout), "Persisted entry is absent from FTS search")
        match.tap()
        XCTAssertTrue(app.navigationBars["Entry"].waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(app.staticTexts[content].exists, "Detail must display the exact persisted content")
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
