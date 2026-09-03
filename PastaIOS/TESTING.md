# Testing PastaIOS

The iOS companion app has an end-to-end XCUITest suite, `PastaIOSUITests`, that
drives the real app on an iPhone simulator. It runs in CI on every push and pull
request (`ios-e2e` job in `.github/workflows/ci.yml`) so a launch crash or a
broken tab can never ship silently again.

The suite needs **no iCloud account** and starts every test from an **empty
database**, so it behaves the same on a fresh CI runner and on your Mac.

## Running locally

```bash
# From the repository root. Any iPhone simulator on the latest runtime works.
xcodebuild test \
  -project PastaIOS/PastaIOS.xcodeproj -scheme PastaIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -resultBundlePath .build/ios-e2e/PastaIOSUITests.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Or open `PastaIOS/PastaIOS.xcodeproj` in Xcode, pick an iPhone simulator, and
press Cmd-U. The `PastaIOS` scheme's Test action runs `PastaIOSUITests`.

Useful variants:

```bash
# Compile everything without running (works with no simulator device present)
xcodebuild build-for-testing -project PastaIOS/PastaIOS.xcodeproj -scheme PastaIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

# Run a single test
xcodebuild test -project PastaIOS/PastaIOS.xcodeproj -scheme PastaIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:PastaIOSUITests/PastaIOSUITests/testLaunchesWithoutCrashing \
  CODE_SIGNING_ALLOWED=NO
```

If `typeText` fails with "Neither element nor any descendant has keyboard
focus", the simulator has a hardware keyboard attached. Run
`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`
and relaunch the simulator (CI does this before booting its device).

If `xcrun simctl create` reports "Device was allocated but was stuck in creation
state" (NSPOSIXErrorDomain 22), CoreSimulator on that Mac is broken; use
`build-for-testing` to type-check locally and let CI run the suite.

## Reading results

```bash
xcrun xcresulttool get test-results summary --path .build/ios-e2e/PastaIOSUITests.xcresult
xcrun xcresulttool get test-results tests   --path .build/ios-e2e/PastaIOSUITests.xcresult
open .build/ios-e2e/PastaIOSUITests.xcresult   # full report in Xcode, incl. crash logs and screenshots
```

When a test fails in CI the job uploads an `ios-e2e-diagnostics` artifact with
the `.xcresult`, any `PastaIOS*` crash reports from the runner and the
simulator, and a `log show` capture of the app process. A launch crash shows up
as `testLaunchesWithoutCrashing` failing with the app state, plus an `.ips`
crash report whose `exception`/`termination` fields name the trap.

## What is covered

| Test | Checks |
| --- | --- |
| `testLaunchesWithoutCrashing` | App reaches the tab bar within 15 s, loading view goes away, process stays in the foreground. **This is the launch-crash guard.** |
| `testSurvivesBackgroundAndForeground` | Home, then re-activate: the activation pipeline (sync + clipboard capture) does not crash. |
| `testHistoryTabShowsListAndEmptyState` | History tab renders its list and either the empty state or rows. |
| `testSearchTabIsReachable`, `testSettingsTabIsReachable`, `testCanCycleThroughAllTabs` | Each tab is selectable and shows its top-level element. |
| `testSearchFieldIsVisibleImmediatelyWithoutScrolling` | Regression for #74: the search field is hittable in the top part of the screen as soon as the tab opens. |
| `testTypingASearchQueryShowsResultsOrEmptyState` | Typing a query does not crash and shows results or the no-results state; clearing returns to the prompt. |
| `testSearchFindsACapturedClipboardEntry` | FTS search finds an entry captured from the pasteboard. |
| `testSettingsRendersItsSections` | Sync/Help/About/Reset sections render; iCloud reads "Unavailable" with no account. |
| `testReplayWalkthroughRoundTrips`, `testWhatsNewSheetRoundTrips` | Settings actions present a sheet and dismissing it returns to Settings. |
| `testFirstLaunchShowsOnboardingAndGetStartedReachesMainUI` | First launch shows onboarding; Get Started reaches the main UI. |
| `testOnboardingCompletionPersistsAcrossRelaunch` | Completed onboarding survives a relaunch. |
| `testSkipOnboardingHookLandsOnMainUI` | The skip hook lands on the main UI with no What's New sheet. |
| `testCapturesPasteboardIntoHistoryOnActivation` | Text on the pasteboard at activation becomes the newest History entry; Settings count agrees. |
| `testOpeningACapturedEntryShowsDetail` | Row -> detail -> back navigation. |

## Launch hooks

The tests control the app through launch arguments and environment variables,
implemented in `PastaIOS/PastaIOS/Services/UITestConfiguration.swift` and
applied in `AppState.init()` before the database or UserDefaults are read.
**None of them do anything unless the `-uiTesting` launch argument is present**,
so a stray environment variable on a real device has no effect.

| Hook | Effect |
| --- | --- |
| `-uiTesting` (launch argument) | Enables the hooks below. |
| `PASTA_UI_TEST_RESET=1` | Deletes `pasta.sqlite` (+ `-wal`/`-shm`) and removes the app's UserDefaults domain, so the run starts from a fresh install. Every test sets this. |
| `PASTA_UI_TEST_SKIP_ONBOARDING=1` | Marks onboarding complete and the current version as seen, so the app opens on the main tab UI without the onboarding or What's New sheets. |
| `PASTA_UI_TEST_PASTEBOARD=<text>` | Writes `<text>` to `UIPasteboard.general` before the activation-time clipboard capture runs, making the capture path deterministic. |

CloudKit is not touched: `PastaIOSApp` constructs `SyncManager` with
`syncEnabled: false`, and `AppState.initialise` treats an unavailable account as
non-fatal, so the suite never needs iCloud.

## Accessibility identifiers

Tests locate views by identifier rather than text where possible. The stable
ones are: `loading.view`, `history.list`, `history.row`, `history.emptyState`,
`search.list`, `search.row`, `search.emptyPrompt`, `search.noResults`,
`settings.list`, `settings.iCloudStatus`, `settings.entryCount`,
`settings.version`, `settings.replayWalkthrough`, `settings.whatsNew`,
`onboarding.title`, `onboarding.primaryButton`, `onboarding.toolbarDone`,
`whatsNew.list`, `whatsNew.done`. Tab bar buttons are matched by their titles
(`History`, `Search`, `Settings`) and the search field via `app.searchFields`.
