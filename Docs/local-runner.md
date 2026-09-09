# Permanent Mac runner

`bravo-mini-pasta` is a repository-scoped ARM64 Actions runner on the Mac mini,
installed in `/Users/bravostation/actions-runners/pasta`. Native CI and release
jobs select the `pasta-local` label. It currently uses Xcode 26.2 (17C52) and the
iOS 26.2 runtime. Hosted fallback for fork PRs still selects macOS 15/Xcode 26.3.
All existing publication and test gates remain required.

The user LaunchAgent starts at login. From the installation directory,
`./svc.sh status`, `./svc.sh stop`, and `./svc.sh start` manage it. Logs are in
`~/Library/Logs/actions.runner.crmitchelmore-pasta.bravo-mini-pasta/` and `_diag/`.
The Mac must be awake and the user logged in for jobs to execute.

Only repository-owned source may execute locally. Fork PR jobs use hosted
runners; GitHub requires approval for every external contributor. A local job
start hook also rejects fork PRs, foreign repositories, and unsupported events.
This runner deliberately has no generic default labels. For another personal
repository, register a separate service with its own repository restriction and
work directory; this registration cannot receive another repository's jobs.

Release jobs retain the original keychain search list, use temporary API keys,
and restore any pre-existing provisioning profile. SwiftPM gets an internal
job cache because the personal cache points at removable storage. The simulator
uses internal storage; the former external CoreSimulator symlink was preserved
as `~/Library/Developer/CoreSimulator.external-backup-20260909`.

`Local runner verification` checks the toolchain and proves the GitHub Sparkle
private key matches the public key in installed Pasta without exporting it.
