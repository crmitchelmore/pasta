# Changelog

All notable changes to Pasta will be documented in this file.

## [0.7.9] - 2026-02-10

### Fixed
- Fixed stale preload cache causing outdated entries to display after data changes.

## [0.7.1] - 2026-01-31

### Changed
- Quick search now shows the 50 most recent clipboard items on open for faster lookback.

## [0.7.0] - 2026-01-28

### Added
- **Command Mode** - Type `!` in quick search to enter command mode with 40+ commands:
  - **Clear commands**: `!clear 10 mins`, `!clear 1 hour`, `!clear 1 day`, `!clear <n> mins/hours/days`, `!clear all`
  - **Monitoring**: `!pause`, `!resume` clipboard monitoring
  - **Settings toggles**: `!sounds on/off`, `!notifications on/off`, `!images on/off`, `!dedupe on/off`, `!extract on/off`, `!skip-api-keys on/off`
  - **Theme control**: `!theme light`, `!theme dark`, `!theme system`
  - **Navigation**: `!settings`, `!updates`, `!release notes`, `!quit`
  - **Quick filters**: `!urls`, `!emails`, `!images`, `!text`, `!code`, `!paths`
  - **Help**: `!help` shows all available commands
- Confirmation dialog for destructive commands (`!clear all`)
- Success feedback after command execution
- Menu bar quick actions: "Clear History" submenu with "Last 10 Minutes" and "Last Hour" options

### Fixed
- Fixed window not appearing when Cmd+Tab to app after closing window (window reference was stale)

## [0.6.48] - Previous Release

See [GitHub Releases](https://github.com/crmitchelmore/pasta/releases) for earlier versions.
