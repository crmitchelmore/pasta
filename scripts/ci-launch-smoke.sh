#!/bin/bash
# Launch-readiness smoke test for a built Pasta.app bundle.
#
# Shared by ci.yml (ad-hoc signed test bundle on every PR), release.yml (the
# Developer-ID signed + notarized bundle, before AND after publishing) so the
# three cannot drift. Proves the app initialised — not merely that it has a
# PID — and that it quits cleanly:
#
#   1. Launch with PASTA_CI=1 (disables CloudKit init and analytics, makes
#      BackgroundService emit `PASTA_CI_READY` on stderr and to
#      PASTA_CI_READY_FILE once the database has answered the initial history
#      load and clipboard monitoring is running on DURABLE storage, and routes
#      SIGTERM through NSApplication.terminate — see
#      Sources/PastaApp/CIReadiness.swift). If a persistent service fell back
#      to volatile storage the app emits `PASTA_CI_DEGRADED reason=<why>`
#      instead and never becomes ready.
#   2. Wait up to READY_TIMEOUT seconds (default 30) for the marker; a
#      PASTA_CI_DEGRADED line fails immediately with its reason.
#   3. kill -TERM and require exit code 0 within QUIT_TIMEOUT seconds (default 15).
#
# On any failure the app's stderr and the relevant unified-log excerpts (AppKit
# termination, Sparkle, AMFI/codesign) are dumped and the script exits 1.
#
# Usage: scripts/ci-launch-smoke.sh <path/to/Pasta.app>
#   READY_TIMEOUT=30  seconds to wait for PASTA_CI_READY
#   QUIT_TIMEOUT=15   seconds to wait for a clean exit after SIGTERM
#   SMOKE_TMP         scratch dir for the marker + stderr log (default RUNNER_TEMP or TMPDIR)

set -euo pipefail

APP_DIR="${1:-}"
if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
  echo "usage: $0 <path/to/Pasta.app>" >&2
  exit 2
fi

READY_TIMEOUT="${READY_TIMEOUT:-30}"
QUIT_TIMEOUT="${QUIT_TIMEOUT:-15}"
SMOKE_TMP="${SMOKE_TMP:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
mkdir -p "$SMOKE_TMP"

INFO_PLIST="$APP_DIR/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || echo PastaApp)"
BINARY="$APP_DIR/Contents/MacOS/$EXECUTABLE"
if [ ! -x "$BINARY" ]; then
  echo "ERROR: executable not found at $BINARY" >&2
  exit 1
fi

READY_FILE="$SMOKE_TMP/pasta-ci-ready"
LAUNCH_LOG="$SMOKE_TMP/pasta-launch-stderr.log"
rm -f "$READY_FILE" "$LAUNCH_LOG"

dump_logs() {
  echo "==> App stderr ($LAUNCH_LOG):"
  cat "$LAUNCH_LOG" 2>/dev/null || true
  echo ""
  echo "==> App os_log (errors, AppKit termination, Sparkle) — last 90s:"
  log show --last 90s --style compact \
    --predicate 'process == "PastaApp" AND (messageType == error OR messageType == fault OR subsystem == "com.apple.AppKit" OR subsystem CONTAINS "sparkle" OR subsystem CONTAINS "pasta")' \
    2>/dev/null | tail -60 || true
  echo ""
  echo "==> System log (AMFI/codesign):"
  log show --last 90s --predicate 'process == "amfid" OR process == "syspolicyd" OR subsystem == "com.apple.MobileFileIntegrity" OR eventMessage CONTAINS "code signature"' 2>/dev/null | tail -20 || true
  echo ""
  echo "Common causes:"
  echo "  - AMFI SIGKILL: restricted entitlement not in provisioning profile"
  echo "  - dyld crash: framework signed with app entitlements"
  echo "  - dyld crash: framework not copied to Contents/Frameworks"
  echo "  - Code signature invalid: binary modified after signing"
  echo "  - Never ready: database open / initial history load / clipboard monitor start did not complete"
  echo "  - PASTA_CI_DEGRADED: durable database or image storage failed and the app fell back to volatile storage"
}

echo "==> Smoke test: launching $APP_DIR"
echo "    bundle version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo '?') ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo '?'))"
echo "    signature:      $(codesign -dvv "$APP_DIR" 2>&1 | grep -E '^(Authority=|Signature=)' | head -1 || echo 'unsigned')"

PASTA_CI=1 PASTA_CI_READY_FILE="$READY_FILE" "$BINARY" 2> "$LAUNCH_LOG" &
APP_PID=$!

# 1. Wait (<= READY_TIMEOUT s) for the app to prove it initialised, not just that it has a PID.
READY=0
DEGRADED=""
for _ in $(seq 1 $((READY_TIMEOUT * 2))); do
  if [ -f "$READY_FILE" ] || grep -q "PASTA_CI_READY" "$LAUNCH_LOG" 2>/dev/null; then
    READY=1
    break
  fi
  # The app knows it will never be ready (volatile-storage fallback): fail now
  # with the reason rather than after READY_TIMEOUT with a generic message.
  DEGRADED=$(grep -m1 "PASTA_CI_DEGRADED" "$LAUNCH_LOG" 2>/dev/null || true)
  if [ -n "$DEGRADED" ]; then
    break
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if [ -n "$DEGRADED" ]; then
  echo "ERROR: App refused readiness: $DEGRADED"
  echo "       A persistent service fell back to volatile storage (in-memory database or temporary image directory); a release build must not ship in this state."
  kill -KILL "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  dump_logs
  exit 1
fi

if [ "$READY" != "1" ]; then
  if kill -0 "$APP_PID" 2>/dev/null; then
    echo "ERROR: App is running (PID $APP_PID) but never reported PASTA_CI_READY within ${READY_TIMEOUT}s."
    echo "       Database open / initial history load / clipboard monitor start did not complete."
    kill -KILL "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  else
    EXIT_CODE=0
    wait "$APP_PID" 2>/dev/null || EXIT_CODE=$?
    echo "ERROR: App exited before becoming ready (exit code $EXIT_CODE)."
  fi
  dump_logs
  exit 1
fi
echo "✓ App initialised: $(cat "$READY_FILE" 2>/dev/null || grep PASTA_CI_READY "$LAUNCH_LOG")"

# 2. Graceful quit must exit 0 — a crash on teardown is a regression too.
echo "==> Sending SIGTERM (routed to NSApplication.terminate under PASTA_CI)..."
kill -TERM "$APP_PID"
( sleep "$QUIT_TIMEOUT"; kill -KILL "$APP_PID" 2>/dev/null ) &
WATCHDOG_PID=$!
EXIT_CODE=0
wait "$APP_PID" || EXIT_CODE=$?
kill "$WATCHDOG_PID" 2>/dev/null || true

if [ "$EXIT_CODE" != "0" ]; then
  if [ "$EXIT_CODE" = "137" ]; then
    echo "ERROR: App did not quit within ${QUIT_TIMEOUT}s of SIGTERM (killed by watchdog)."
  else
    echo "ERROR: App exited with code $EXIT_CODE on quit (expected 0)."
  fi
  dump_logs
  exit 1
fi
echo "✓ App quit cleanly (exit 0)"

echo "==> Smoke test PASSED!"
