# macOS permission setup

Accessibility enables direct pasting into other apps. Without it, Pasta still
captures and copies clips so the user can paste manually. The Carbon default
shortcut does not need Input Monitoring. Automatic snippet expansion is opt-in
and requires both Accessibility and Input Monitoring; setup is offered alongside
that switch in Settings → Snippets.

`MacPermissionStore` publishes one main-actor snapshot of the current process's
public OS checks. Onboarding, the panel banner, General Settings and snippet
settings observe it directly. App activation refreshes silently. Visible setup
sessions poll at 0.5 seconds for at most two minutes and stop on grant or dismissal.
A check never assumes that opening Settings or adding an app grants access.

`MacPermissionGuidance` owns one nonactivating AppKit panel. A native SwiftUI
illustration avoids an additional dependency in the shared macOS/iOS package.
Every explicit entry point replaces the previous guide and opens the matching
Settings pane. The card uses the running bundle URL and Finder name, including
Alpha, Development and renamed copies. Non-bundled executables get a launch-a-bundle
fallback. The exact app path can be copied; the + button in System Settings is the
keyboard alternative to dragging. Reduce Motion disables the decorative arrow.
The standard Window menu, Return (Check Again), and Escape support keyboard use.
Opening failures retain the full manual navigation path. A fresh Check Again
reports success or the missing permission; follow a restart only when macOS asks.

`SnippetExpansionController` subscribes to permission changes and refreshes on
activation, including failed monitor registration. `PermissionDependentMonitor`
starts once, removes the event monitor on revocation or opt-out, and retries when
access returns. Event handling and asynchronous text replacement also check actual
access before operating. Snapshot changes invalidate an in-progress expansion.

## Verification

Run `swift test --parallel` and `script/build_and_run.sh --verify`. Tests inject
permission readers rather than consulting the host's grants. They cover multiple
subscribers, grant/revocation, activation after polling stops, finite polling,
dismissal and teardown, monitor rearming/registration failure, repeated Settings
requests, failed links and build identity. Existing paste tests cover copy-only
fallback and are independent of the host's Accessibility permission.

In the bundled app, exercise onboarding, the panel banner, General Settings and
both snippet setup rows. Repeated actions must leave one guide. Confirm the actual
Settings destination, exact app name/path, missing-access feedback and dismissal.
Use an isolated identity for any user-led grant/revocation verification, then
exercise the protected paste and expansion features. A signed bundle inspection,
a guide screenshot and real TCC/feature verification are separate evidence.

Never reset the user's TCC database or re-sign their installed app for testing.
Alpha delivery follows `Docs/release-trains.md` once that release infrastructure
has merged. This permission change does not approve a Stable promotion.
