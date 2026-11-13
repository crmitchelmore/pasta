import XCTest

/// End-to-end journeys through the PastaIOS companion app on a simulator with
/// no iCloud account. Each journey starts from an empty database and
/// pasteboard; launches are slow, so every test chains several user-visible
/// checks and relaunches instead of paying for a fresh launch per assertion.
/// Run with:
///
///     xcodebuild test -project PastaIOS/PastaIOS.xcodeproj -scheme PastaIOS \
///       -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
///       CODE_SIGNING_ALLOWED=NO
///
/// See `PastaIOS/TESTING.md`.
final class PastaIOSUITests: PastaUITestCase {

    // MARK: - Launch, onboarding and empty history

    /// The launch-crash guard. A Swift runtime trap during
    /// `AppState.initialise` (database migration, CloudKit, clipboard capture)
    /// terminates the process before onboarding or the tab bar exists, and
    /// XCTest attaches the crash report to the result bundle. The journey then
    /// proves the empty install is exactly empty, the Search field is usable
    /// at once (#74), the activation pipeline survives background/foreground,
    /// and completed onboarding survives a relaunch.
    func testFreshLaunchOnboardingEmptyHistoryAndLifecycle() {
        launchApp(skipOnboarding: false)

        let title = element("onboarding.title")
        XCTAssertTrue(
            title.waitForExistence(timeout: Self.launchTimeout),
            "Onboarding did not appear on first launch (app state: \(app.state.rawValue))"
        )
        XCTAssertEqual(title.label, "Welcome to Pasta", "First launch must show the welcome flow, not the replay")
        XCTAssertFalse(tabBar.exists, "Tab bar visible while onboarding is showing")
        tapOnboardingPrimaryButton()

        waitForMainUI()
        XCTAssertFalse(title.exists, "Onboarding still visible after Get Started")
        XCTAssertFalse(element("whatsNew.list").exists, "What's New sheet shown on a fresh install")
        XCTAssertTrue(
            waitForDisappearance(of: element("loading.view"), timeout: Self.launchTimeout),
            "Loading view is still visible; AppState.initialise never finished"
        )
        XCTAssertTrue(element("history.list").exists, "History list is not the root content after launch")
        XCTAssertTrue(element("history.emptyState").waitForExistence(timeout: Self.uiTimeout))
        XCTAssertFalse(element("history.row").exists, "Fresh install unexpectedly contains history")

        // Regression for #74: the search field must be visible as soon as the
        // Search tab opens (`.navigationBarDrawer(displayMode: .always)`).
        openTab("Search", expecting: "search.list")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout), "Search field never appeared")
        XCTAssertTrue(searchField.isHittable, "Search field exists but is not hittable without scrolling")
        let window = app.windows.firstMatch.frame
        let field = searchField.frame
        XCTAssertGreaterThan(field.height, 0)
        XCTAssertTrue(window.contains(field), "Search field is off-screen: \(field) not inside \(window)")
        XCTAssertLessThan(
            field.maxY,
            window.minY + window.height * 0.4,
            "Search field is not in the top part of the screen: \(field) in \(window)"
        )
        XCTAssertTrue(element("search.emptyPrompt").exists, "Empty search must show its prompt")

        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "0")
        // Completed onboarding is not permission to upload clipboard history.
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Off"))
        let version = element("settings.version")
        revealSettingsRow(version)
        XCTAssertTrue(version.waitForExistence(timeout: Self.uiTimeout), "Version row missing")
        XCTAssertFalse(version.label.isEmpty, "Version row is blank")

        // Backgrounding and re-activating re-runs sync + clipboard capture.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.uiTimeout), "App did not move to the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout), "App did not return to the foreground")
        XCTAssertTrue(tabBar.waitForExistence(timeout: Self.uiTimeout), "Tab bar missing after re-activation")

        // Relaunch without the skip hook: completed onboarding must persist.
        relaunch(skipOnboarding: false)
        XCTAssertFalse(element("onboarding.title").exists, "Onboarding re-appeared after completing it")
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "0", "An empty install must stay empty across relaunch")

        // Replaying the walkthrough presents it and returns to Settings.
        let replay = element("settings.replayWalkthrough")
        revealSettingsRow(replay)
        replay.tap()
        let walkthrough = element("onboarding.title")
        XCTAssertTrue(walkthrough.waitForExistence(timeout: Self.uiTimeout), "Walkthrough sheet did not appear")
        XCTAssertEqual(walkthrough.label, "Pasta Walkthrough", "Replay must not restart first-run onboarding")
        tapOnboardingPrimaryButton()
        XCTAssertTrue(waitForDisappearance(of: walkthrough), "Walkthrough sheet did not dismiss")
        XCTAssertTrue(element("settings.list").exists, "Settings list gone after dismissing the walkthrough")
        XCTAssertTrue(tabButton("Settings").isSelected, "Settings tab lost selection after the sheet")
    }

    // MARK: - Capture, detail, search and persistence

    /// Pasteboard text at activation is captured exactly once, opens in
    /// detail, is found by FTS search while unrelated queries return nothing,
    /// and survives termination. The relaunch puts an unrelated URL on the
    /// pasteboard, so the first entry can only come back from the on-disk
    /// database, not by recapturing the fixture, and the URL must be classified.
    func testCaptureDetailSearchAndPersistenceAcrossRelaunch() {
        let token = "PastaJourney\(UUID().uuidString.prefix(8))"
        let content = "Captured clipboard content \(token)"
        launchApp(pasteboard: content)
        waitForMainUI()

        openTab("History", expecting: "history.list")
        let row = app.staticTexts[content].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.uiTimeout), "Captured clipboard entry not shown in History")
        XCTAssertFalse(element("history.emptyState").exists, "Empty state shown although an entry was captured")

        row.tap()
        let detailBar = app.navigationBars["Entry"]
        // A tap landing while the list is still settling after the capture can be dropped.
        if !detailBar.waitForExistence(timeout: 5), app.navigationBars["Clipboard History"].exists {
            row.tap()
        }
        XCTAssertTrue(detailBar.waitForExistence(timeout: Self.uiTimeout), "Entry detail screen did not open")
        XCTAssertTrue(app.staticTexts[content].firstMatch.waitForExistence(timeout: Self.uiTimeout),
                      "Detail must display the captured content")
        let back = detailBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: Self.uiTimeout), "No back button on the detail screen")
        back.tap()
        XCTAssertTrue(app.navigationBars["Clipboard History"].waitForExistence(timeout: Self.uiTimeout),
                      "Back did not return to the History list")

        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "1", "One clipboard capture must produce exactly one stored entry")

        openTab("Search", expecting: "search.list")
        let searchField = search(for: token)
        XCTAssertTrue(element("search.row").waitForExistence(timeout: Self.uiTimeout), "Known query must return the captured entry")
        // Start from a populated result set so the no-results assertion cannot
        // pass against the initial empty UI before the async search completes.
        searchField.typeText(" zzqxnosuchentry\(UUID().uuidString.prefix(8))")
        XCTAssertTrue(element("search.noResults").waitForExistence(timeout: Self.uiTimeout), "Unmatched query must show no results")
        XCTAssertTrue(waitForDisappearance(of: element("search.row")), "Search retained an unrelated result")
        searchField.buttons.firstMatch.tap()
        XCTAssertTrue(element("search.emptyPrompt").waitForExistence(timeout: Self.uiTimeout), "Clearing must return to the prompt")
        XCTAssertFalse(element("search.row").exists)

        // The replacement is a URL, so the capture must run the shared
        // detectors rather than storing everything as plain text.
        let replacementURL = "https://example.com/pasta-\(token)"
        relaunch(pasteboard: replacementURL)
        XCTAssertTrue(app.staticTexts[content].waitForExistence(timeout: Self.uiTimeout), "Captured history was lost across relaunch")
        XCTAssertTrue(app.staticTexts[replacementURL].waitForExistence(timeout: Self.uiTimeout), "Replacement URL was not captured")
        XCTAssertTrue(app.staticTexts["URL"].firstMatch.exists, "Captured URL must be labelled URL, not Text")
        openTab("Settings", expecting: "settings.list")
        XCTAssertEqual(element("settings.entryCount").label, "2", "Relaunch must retain the first entry and capture the replacement once")
        openTab("Search", expecting: "search.list")
        search(for: token)
        let match = app.staticTexts[content]
        XCTAssertTrue(match.waitForExistence(timeout: Self.uiTimeout), "Persisted entry is absent from FTS search")
        match.tap()
        XCTAssertTrue(app.navigationBars["Entry"].waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(app.staticTexts[content].exists, "Detail must display the exact persisted content")
    }

    // MARK: - Sync settings

    /// Diagnostics and Reset Sync both work without consent or an iCloud
    /// account, never leak clipboard contents, never replace the pasteboard,
    /// never grant consent and never delete local history.
    func testSyncDiagnosticsAndResetKeepOfflineHistoryWithoutGrantingConsent() {
        let privateContent = "PrivateDiagnosticHistory\(UUID().uuidString.prefix(8))"
        launchApp(pasteboard: privateContent)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")

        let diagnostics = element("settings.syncDiagnostics")
        revealSettingsRow(diagnostics)
        XCTAssertTrue(diagnostics.isHittable, "Diagnostics must remain available without iCloud sync consent")
        diagnostics.tap()
        let report = element("syncDiagnostics.report")
        XCTAssertTrue(report.waitForExistence(timeout: Self.uiTimeout), "Diagnostics report missing in the unprovisioned simulator")
        let copy = app.buttons["syncDiagnostics.copy"].firstMatch
        waitUntilEnabled(copy, "Diagnostics collection never finished")
        XCTAssertTrue(report.label.contains("iCloud.com.pasta.ios"), "Report must identify the shared CloudKit container")
        XCTAssertFalse(report.label.contains(privateContent), "Diagnostics must exclude clipboard contents")
        XCTAssertTrue(copy.isHittable, "Copy Report must be reachable without scrolling through the report")
        let refresh = app.buttons["syncDiagnostics.refresh"].firstMatch
        XCTAssertTrue(refresh.isHittable)
        refresh.tap()
        waitUntilEnabled(copy, "Diagnostics refresh never finished")
        XCTAssertFalse(report.label.contains(privateContent))
        let done = app.buttons["syncDiagnostics.done"].firstMatch
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(waitForDisappearance(of: done), "Done must dismiss diagnostics")

        let reset = element("settings.resetSync")
        revealSettingsRow(reset, scrollUp: false)
        XCTAssertTrue(reset.isHittable, "Reset Sync must be reachable by scrolling")
        reset.tap()
        let confirmation = app.alerts["Reset iCloud Sync?"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(confirmation.staticTexts[
            "Your local history and iCloud data are kept. Pasta will download iCloud history again when sync is enabled and connected."
        ].exists, "Reset must explain its effect before confirming")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(of: confirmation))
        XCTAssertFalse(element("settings.syncFeedback").exists, "Cancelling must not claim a reset")

        reset.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.uiTimeout))
        // SwiftUI exposes nested accessibility buttons for this alert action.
        // Scope to its identifier and choose one representation of the action.
        let confirmReset = confirmation.buttons["settings.confirmResetSync"].firstMatch
        XCTAssertTrue(confirmReset.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertTrue(confirmReset.isHittable, "Reset confirmation must be actionable")
        confirmReset.tap()
        XCTAssertTrue(waitForDisappearance(of: confirmation))
        let feedback = element("settings.syncFeedback")
        revealSettingsRow(feedback, scrollUp: false)
        XCTAssertTrue(feedback.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(feedback.label, "Sync reset. Local history kept. Enable iCloud Sync to download your history again.")
        XCTAssertFalse(feedback.label.contains("Sync complete"), "A local-only reset is not a successful cloud sync")
        assertEntryCount("1", "Reset must keep local history")

        // Relaunching recaptures the pasteboard: a second entry would expose
        // an accidental report copy or clipboard replacement.
        relaunch()
        openTab("History", expecting: "history.list")
        XCTAssertTrue(app.staticTexts[privateContent].firstMatch.waitForExistence(timeout: Self.uiTimeout),
                      "Reset and diagnostics must keep persisted clipboard history")
        openTab("Settings", expecting: "settings.list")
        assertConsent(false, "Reset and diagnostics must not grant sync consent")
        assertEntryCount("1", "Diagnostics must retain history and leave the pasteboard unchanged")
    }

    /// Sync starts only with explicit consent. A failed retry in the
    /// unprovisioned simulator gives a visible next action and keeps offline
    /// history; consent and its withdrawal both persist across relaunch.
    func testSyncConsentRetryAndWithdrawalPersistWithoutDeletingHistory() {
        let token = "OfflineRecovery\(UUID().uuidString.prefix(8))"
        launchApp(pasteboard: token)
        waitForMainUI()
        openTab("Settings", expecting: "settings.list")
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Off"))
        XCTAssertFalse(element("settings.syncNow").isEnabled, "Sync requires explicit consent")
        XCTAssertTrue(element("settings.iCloudConsentExplanation").exists, "Consent must be explained before it is given")
        XCTAssertTrue(element("settings.iCloudGuidance").waitForExistence(timeout: Self.uiTimeout),
                      "Unavailable iCloud must explain how to recover")
        assertEntryCount("1", "One clipboard capture must produce exactly one stored entry")

        setSyncConsent(true)
        let syncNow = element("settings.syncNow")
        revealSettingsRow(syncNow)
        waitUntilEnabled(syncNow, "Account check never finished after consent")
        syncNow.tap()
        waitUntilEnabled(element("settings.syncNow"), "Sync retry never finished")
        let failure = element("settings.syncError")
        XCTAssertTrue(failure.waitForExistence(timeout: Self.uiTimeout), "Failed retry must give a visible next action")
        XCTAssertTrue(failure.label.contains("update"), "The unprovisioned simulator must explain which action to take")
        XCTAssertFalse(failure.label.contains("Sync complete"))
        assertEntryCount("1", "Retry must retain offline clipboard history")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.uiTimeout))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.uiTimeout))
        openTab("History", expecting: "history.list")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", token))
            .firstMatch.waitForExistence(timeout: Self.uiTimeout), "Retry and re-activation must keep offline history")

        relaunch()
        openTab("Settings", expecting: "settings.list")
        assertConsent(true, "Consent must persist across relaunch")
        assertEntryCount("1", "Offline history must survive relaunch after retries")
        setSyncConsent(false)
        XCTAssertTrue(element("settings.iCloudStatus").label.contains("Off"))
        XCTAssertFalse(element("settings.syncNow").isEnabled, "Withdrawn consent must disable Sync Now")

        relaunch()
        openTab("Settings", expecting: "settings.list")
        assertConsent(false, "Withdrawn consent must persist across relaunch")
        assertEntryCount("1", "Withdrawing consent must not delete history")
    }

    /// A detected secret copied on the device is stored locally, marked as
    /// kept on the device, and only later copies follow the opt-in setting.
    func testDetectedSecretsStayLocalUntilTheUserOptsIn() {
        let suffix = UUID().uuidString.prefix(8)
        let secret = "API_KEY=localonly\(suffix)"
        launchApp(pasteboard: secret)
        waitForMainUI()
        openTab("History", expecting: "history.list")
        let row = app.staticTexts[secret].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Self.uiTimeout), "Secret was not captured locally")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "history.row.localOnly").count, 1,
                       "A detected secret must be marked as kept on this device")
        row.tap()
        XCTAssertTrue(element("detail.localOnly").waitForExistence(timeout: Self.uiTimeout),
                      "Detail must explain the secret is not uploaded")

        openTab("Settings", expecting: "settings.list")
        let toggle = app.switches["settings.syncDetectedSecrets"].firstMatch
        revealSettingsRow(toggle, scrollUp: false)
        XCTAssertEqual(toggle.value as? String, "0", "Secrets must stay local by default")
        setSyncConsent(true, switch: "settings.syncDetectedSecrets")

        let later = "OTHER_KEY=synced\(suffix)"
        relaunch(pasteboard: later)
        openTab("History", expecting: "history.list")
        XCTAssertTrue(app.staticTexts[later].firstMatch.waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "history.row.localOnly").count, 1,
                       "Opting in applies only to later copies")
        openTab("Settings", expecting: "settings.list")
        revealSettingsRow(toggle, scrollUp: false)
        XCTAssertEqual(toggle.value as? String, "1", "The opt-in must persist across relaunch")
        assertConsent(false, "Syncing secrets must not grant iCloud consent")
    }

    // MARK: - Release notes

    // Release-note journeys use real persisted defaults and bundled history.
    // Version/build overrides avoid coupling tests to CI's archive numbering.

    /// Upgrading from the legacy version-only marker presents the notes; they
    /// are acknowledged only on dismissal (not by killing the app), and
    /// Settings can replay them, navigate to earlier versions and dismiss.
    func testReleaseNotesUpgradeAcknowledgesOnlyAfterDismissalAndReplaysFromSettings() {
        app.launchEnvironment["PASTA_UI_TEST_VERSION"] = "1.5.18"
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "140"
        app.launchEnvironment["PASTA_UI_TEST_PREVIOUS_VERSION"] = "1.5.17"
        launchApp(skipOnboarding: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        XCTAssertEqual(element("whatsNew.installedVersion").label, "Version 1.5.18 (140)")
        XCTAssertEqual(element("whatsNew.summary").label, "More reliable clipboard history shared from your Mac.")

        // Killing the app with notes still open must not consume the update.
        app.launchEnvironment["PASTA_UI_TEST_PREVIOUS_VERSION"] = nil
        relaunch(skipOnboarding: false, waitForMain: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        app.buttons["whatsNew.done"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(of: element("whatsNew.list")))

        relaunch(skipOnboarding: false)
        XCTAssertFalse(element("whatsNew.list").exists, "Dismissed notes must stay acknowledged")

        openTab("Settings", expecting: "settings.list")
        let whatsNew = element("settings.whatsNew")
        revealSettingsRow(whatsNew)
        whatsNew.tap()
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.uiTimeout), "What's New sheet did not appear")
        // A toolbar Button surfaces its identifier on both the toolbar item and
        // the button, so narrow to the button type and take the first match.
        let done = app.buttons["whatsNew.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: Self.uiTimeout), "Done button missing on What's New")
        done.tap()
        XCTAssertTrue(waitForDisappearance(of: element("whatsNew.list")), "What's New sheet did not dismiss")
        XCTAssertTrue(element("settings.list").exists, "Settings list gone after dismissing What's New")

        whatsNew.tap()
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.uiTimeout))
        let earlier = element("whatsNew.history.1.5.17:version")
        if !earlier.isHittable { element("whatsNew.list").swipeUp() }
        earlier.tap()
        XCTAssertTrue(element("whatsNew.detail").waitForExistence(timeout: Self.uiTimeout))
        XCTAssertEqual(element("whatsNew.summary").label, "More private diagnostics.")
    }

    /// A new build of an acknowledged marketing version presents its notes,
    /// swipe dismissal acknowledges them, and a later version without bundled
    /// notes says so explicitly instead of relabelling older copy.
    func testNewBuildSwipeDismissalPersistsAndMissingNotesAreExplicit() {
        app.launchEnvironment["PASTA_UI_TEST_VERSION"] = "1.5.18"
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "140"
        launchApp()
        waitForMainUI()
        XCTAssertFalse(element("whatsNew.list").exists, "Acknowledged build must not present its notes")

        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "141"
        relaunch(skipOnboarding: false, waitForMain: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        XCTAssertEqual(element("whatsNew.installedVersion").label, "Version 1.5.18 (141)")
        // Start outside the list and drag across the window. A swipe confined
        // to the navigation bar can end before the sheet dismissal threshold.
        let bar = app.navigationBars["What’s New"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: Self.uiTimeout), "What's New navigation bar missing")
        XCTAssertTrue(bar.isHittable, "What's New navigation bar must be ready for the dismissal gesture")
        let dragStart = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        XCTAssertTrue(waitForDisappearance(of: element("whatsNew.list")),
                      "Dragging the What's New sheet down must dismiss it")

        relaunch(skipOnboarding: false)
        XCTAssertFalse(element("whatsNew.list").exists, "Swipe dismissal must acknowledge the build")

        app.launchEnvironment["PASTA_UI_TEST_VERSION"] = "9.0.0"
        app.launchEnvironment["PASTA_UI_TEST_BUILD"] = "999"
        relaunch(skipOnboarding: false, waitForMain: false)
        XCTAssertTrue(element("whatsNew.list").waitForExistence(timeout: Self.launchTimeout))
        XCTAssertEqual(element("whatsNew.installedVersion").label, "Version 9.0.0 (999)")
        XCTAssertTrue(element("whatsNew.unavailable").exists, "Missing notes must be explicit")
        XCTAssertFalse(element("whatsNew.summary").exists, "Missing notes must not relabel older copy")
    }

    // MARK: - Helpers

    /// Terminates and relaunches on the persisted database and defaults.
    private func relaunch(
        skipOnboarding: Bool = true,
        pasteboard: String? = nil,
        waitForMain: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.terminate()
        launchApp(skipOnboarding: skipOnboarding, pasteboard: pasteboard, resetState: false)
        if waitForMain { waitForMainUI(file: file, line: line) }
    }

    private func tapOnboardingPrimaryButton(file: StaticString = #filePath, line: UInt = #line) {
        let button = element("onboarding.primaryButton")
        XCTAssertTrue(button.waitForExistence(timeout: Self.uiTimeout), "Onboarding primary button missing", file: file, line: line)
        if !button.isHittable { app.swipeUp() }
        button.tap()
    }

    @discardableResult
    private func search(for text: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: Self.uiTimeout), "Search field missing", file: file, line: line)
        field.tap()
        field.typeText(text)
        return field
    }

    private func waitUntilEnabled(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: Self.uiTimeout), .completed, message, file: file, line: line)
    }

    private func assertEntryCount(_ expected: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let count = element("settings.entryCount")
        revealSettingsRow(count)
        XCTAssertEqual(count.label, expected, message, file: file, line: line)
    }

    private func assertConsent(_ enabled: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.switches["settings.iCloudConsent"].firstMatch
        revealSettingsRow(control, scrollUp: false)
        XCTAssertEqual(control.value as? String, enabled ? "1" : "0", message, file: file, line: line)
    }

    /// Tap the native switch, not the text/container SwiftUI also exposes.
    /// Verify the visible state before testing persistence or starting a retry.
    private func setSyncConsent(
        _ enabled: Bool,
        switch identifier: String = "settings.iCloudConsent",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let control = app.switches[identifier].firstMatch
        revealSettingsRow(control, scrollUp: false)
        XCTAssertTrue(control.waitForExistence(timeout: Self.uiTimeout), "Switch \(identifier) missing", file: file, line: line)
        XCTAssertTrue(control.isHittable, "Sync consent switch is not reachable", file: file, line: line)
        XCTAssertEqual(control.value as? String, enabled ? "0" : "1", "Journey must start in the opposite consent state", file: file, line: line)
        // SwiftUI may give the switch a full-row frame including its label.
        // The trailing edge is the actual switch thumb on this English UI.
        let target = enabled ? "1" : "0"
        let original = enabled ? "0" : "1"
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // A tap landing while the list is still decelerating from a reveal
        // swipe only stops the scroll. Retap solely if the state is unchanged,
        // so a slow toggle can never be flipped back.
        let quick = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", target), object: control)
        if XCTWaiter().wait(for: [quick], timeout: 2) != .completed, control.value as? String == original {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", target), object: control)
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
}
