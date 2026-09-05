#!/bin/bash
# iOS XCUITest e2e suite driver, shared by ci.yml (`ios-e2e`, every PR) and
# release-ios.yml (`preflight`, before any TestFlight upload) so the two cannot
# drift. Each subcommand is one workflow step; state (the simulator UDID) is
# handed between steps through $GITHUB_ENV when running under Actions and
# through $STATE_DIR/sim-udid otherwise.
#
# Usage: scripts/ci-ios-e2e.sh <create-simulator|resolve|verify-release-settings|build-for-testing|test|summarise|diagnostics|cleanup|all>
#
# Environment (defaults match ci.yml):
#   PROJECT        PastaIOS/PastaIOS.xcodeproj
#   SCHEME         PastaIOS
#   DERIVED_DATA   .build/ios-derived
#   RESULT_BUNDLE  .build/ios-e2e/PastaIOSUITests.xcresult
#   DIAG_DIR       .build/ios-e2e/diagnostics
#   SIM_NAME       PastaCI iPhone
#   SIM_UDID       set by create-simulator; export it yourself to reuse a booted simulator
#
# build-for-testing works without a simulator (generic destination), so the
# compile half can be verified on a Mac where simctl cannot create devices.

set -euo pipefail

PROJECT="${PROJECT:-PastaIOS/PastaIOS.xcodeproj}"
SCHEME="${SCHEME:-PastaIOS}"
DERIVED_DATA="${DERIVED_DATA:-.build/ios-derived}"
RESULT_BUNDLE="${RESULT_BUNDLE:-.build/ios-e2e/PastaIOSUITests.xcresult}"
DIAG_DIR="${DIAG_DIR:-.build/ios-e2e/diagnostics}"
SIM_NAME="${SIM_NAME:-PastaCI iPhone}"
STATE_DIR="${STATE_DIR:-.build/ios-e2e}"
BUILD_LOG="$STATE_DIR/build.log"
TEST_LOG="$STATE_DIR/test.log"

mkdir -p "$STATE_DIR"

# Resolve SIM_UDID from the environment or the state file left by create-simulator.
if [ -z "${SIM_UDID:-}" ] && [ -f "$STATE_DIR/sim-udid" ]; then
  SIM_UDID="$(cat "$STATE_DIR/sim-udid")"
fi
SIM_UDID="${SIM_UDID:-}"

destination() {
  if [ -n "$SIM_UDID" ]; then
    echo "platform=iOS Simulator,id=$SIM_UDID"
  else
    echo "generic/platform=iOS Simulator"
  fi
}

cmd_create_simulator() {
  # The XCUITest keyboard needs the software keyboard; a "connected"
  # hardware keyboard makes typeText fail with no keyboard focus.
  defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false

  RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rts[-1]["identifier"])')
  DEVICE_TYPE=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
types = json.load(sys.stdin)["devicetypes"]
for wanted in ("iPhone 17", "iPhone 16", "iPhone 16e", "iPhone 15"):
    for t in types:
        if t["name"] == wanted:
            print(t["identifier"]); sys.exit(0)
print(types[0]["identifier"])')
  echo "==> Runtime: $RUNTIME"
  echo "==> Device type: $DEVICE_TYPE"
  UDID=$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME")
  printf '%s' "$UDID" > "$STATE_DIR/sim-udid"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "SIM_UDID=$UDID" >> "$GITHUB_ENV"
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "udid=$UDID" >> "$GITHUB_OUTPUT"
  fi
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b
  echo "==> Booted $SIM_NAME ($UDID)"
  SIM_UDID="$UDID"
}

cmd_resolve() {
  xcodebuild -resolvePackageDependencies \
    -project "$PROJECT" -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA"
}

# The Release configuration must carry PASTA_IOS_CLOUDKIT_PROVISIONED, the
# compile-time gate that lets SyncManager touch CloudKit (see
# Sources/PastaSync/SyncManager.swift). It has to live in the app target's
# Release build settings: passing it on the xcodebuild command line applies to
# every target and replaces the SWIFT_PACKAGE define GRDB needs to import its
# SQLite shim, which is exactly how the v1.5.9 TestFlight archive failed.
# Without the flag a TestFlight build ships with iCloud sync silently disabled.
cmd_verify_release_settings() {
  echo "==> Verifying Release build settings for $SCHEME"
  local settings conds
  if ! settings="$(xcodebuild -showBuildSettings \
      -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' 2>&1)"; then
    echo "::error::xcodebuild -showBuildSettings failed for $SCHEME (Release); cannot prove the CloudKit compile flag is set."
    printf '%s\n' "$settings" | tail -20
    return 1
  fi
  conds="$(printf '%s\n' "$settings" \
    | awk -F' = ' '/^ *SWIFT_ACTIVE_COMPILATION_CONDITIONS = /{print $2; exit}')"
  case " $conds " in
    *" PASTA_IOS_CLOUDKIT_PROVISIONED "*)
      echo "    Release SWIFT_ACTIVE_COMPILATION_CONDITIONS = $conds"
      ;;
    *)
      echo "::error::Release configuration of $SCHEME lacks PASTA_IOS_CLOUDKIT_PROVISIONED (got '${conds:-<unset>}'); a TestFlight build would ship with CloudKit sync disabled. Set it in the app target's Release build settings in $PROJECT, not on the xcodebuild command line."
      return 1
      ;;
  esac
}

# Preserve the tool and log-writer statuses: success text is not proof that
# xcodebuild exited successfully (it can fail during result finalisation).
run_xcodebuild_logged() {
  local log_file="$1" pattern="$2"
  shift 2
  local statuses
  set +e
  xcodebuild "$@" 2>&1 | tee "$log_file" | grep -E "$pattern"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [ "${statuses[0]}" != "0" ] || [ "${statuses[1]}" != "0" ]; then
    echo "::error::xcodebuild exited ${statuses[0]}; log writer exited ${statuses[1]}. See $log_file."
    return 1
  fi
}

cmd_build_for_testing() {
  cmd_verify_release_settings || return 1
  echo "==> Destination: $(destination)"
  run_xcodebuild_logged "$BUILD_LOG" "^(=== |\\*\\* |error:|.*error:|.*warning: .*PastaIOS)" build-for-testing \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$(destination)" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO || return 1
  # Require the expected operation to finish as well as a zero exit status.
  grep -q "\*\* TEST BUILD SUCCEEDED \*\*" "$BUILD_LOG"
}

cmd_test() {
  if [ -z "$SIM_UDID" ]; then
    echo "::error::SIM_UDID is not set; run 'create-simulator' first (or export SIM_UDID)."
    exit 1
  fi
  mkdir -p "$(dirname "$RESULT_BUNDLE")"
  rm -rf "$RESULT_BUNDLE"
  run_xcodebuild_logged "$TEST_LOG" "Test Case|Test Suite|passed|failed|error|Executed|Restarting|crash" test-without-building \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$(destination)" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 || return 1
  grep -q "\*\* TEST EXECUTE SUCCEEDED \*\*" "$TEST_LOG" || return 1

  # A successful xcodebuild invocation can execute zero tests. The result
  # bundle must independently prove a nonempty, entirely passing run. Do not
  # retry failures into a green release gate; diagnose flakes from artifacts.
  mkdir -p "$DIAG_DIR"
  local summary="$DIAG_DIR/xcresult-summary.json"
  if ! xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" > "$summary"; then
    echo "::error::Cannot read the XCUITest result bundle; coverage is unverified."
    return 1
  fi
  python3 - "$summary" <<'PYRESULT'
import json, sys
with open(sys.argv[1]) as handle:
    result = json.load(handle)
counts = [result.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
if (not all(type(value) is int for value in counts)
        or result.get("result") != "Passed"
        or counts[0] <= 0 or counts[1] != counts[0]
        or counts[2:] != [0, 0] or result.get("testFailures")):
    print(f"::error::XCUITest coverage gate requires a nonempty run with every test passing: {result}", file=sys.stderr)
    sys.exit(1)
print(f"Verified {counts[1]} passing XCUITests; none failed or skipped.")
PYRESULT
}

cmd_summarise() {
  set +e
  mkdir -p "$DIAG_DIR"
  SUMMARY_OUT="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  if [ ! -d "$RESULT_BUNDLE" ]; then
    echo "No result bundle produced at $RESULT_BUNDLE" >> "$SUMMARY_OUT"
    return 0
  fi
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" > "$DIAG_DIR/xcresult-summary.json" 2>/dev/null
  xcrun xcresulttool get test-results tests   --path "$RESULT_BUNDLE" > "$DIAG_DIR/xcresult-tests.json"   2>/dev/null
  python3 - "$DIAG_DIR/xcresult-summary.json" "$DIAG_DIR/xcresult-tests.json" >> "$SUMMARY_OUT" <<'PY'
import json, sys

def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception as exc:
        print(f"(could not read {path}: {exc})")
        return {}

summary, tests = load(sys.argv[1]), load(sys.argv[2])
print("## iOS E2E results")
result = summary.get("result", "unknown")
print(f"- Result: **{result}** — passed {summary.get('passedTests', '?')}, "
      f"failed {summary.get('failedTests', '?')}, skipped {summary.get('skippedTests', '?')}")
for failure in summary.get("testFailures", []):
    text = (failure.get("failureText") or "").splitlines()
    first = text[0] if text else ""
    print(f"- FAILED `{failure.get('testName')}`: {first}")
print()
print("```")

def walk(nodes, depth=0):
    for node in nodes:
        kind = node.get("nodeType", "")
        if kind in ("Test Case", "Test Suite", "Unit test bundle", "UI test bundle"):
            res = node.get("result", "")
            print("  " * depth + f"{res:<8} {node.get('name', '')} {node.get('duration', '')}")
        walk(node.get("children", []), depth + 1)

walk(tests.get("testNodes", []))
print("```")
PY
  return 0
}

cmd_diagnostics() {
  set +e
  mkdir -p "$DIAG_DIR"

  echo "==> Crash reports (host DiagnosticReports)"
  for dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
    find "$dir" -maxdepth 1 \( -name 'PastaIOS*' -o -name 'PastaIOSUITests*' -o -name 'xctest*' \) \
      -newer "$PROJECT/project.pbxproj" -exec cp -v {} "$DIAG_DIR/" \; 2>/dev/null
  done
  # Simulator-side crash reports live under the device's data directory.
  if [ -n "$SIM_UDID" ]; then
    SIM_DATA="$HOME/Library/Developer/CoreSimulator/Devices/$SIM_UDID/data"
    for sub in Library/Logs/DiagnosticReports Library/Logs/CrashReporter; do
      [ -d "$SIM_DATA/$sub" ] && find "$SIM_DATA/$sub" -type f -exec cp -v {} "$DIAG_DIR/" \; 2>/dev/null
    done
  fi

  echo "==> Print any crash headers we found"
  for f in "$DIAG_DIR"/*.ips "$DIAG_DIR"/*.crash; do
    [ -f "$f" ] || continue
    echo "----- $f"
    grep -E '"procName"|"exception"|"termination"|Exception Type|Termination Reason|Crashed:' "$f" | head -20
  done

  echo "==> Simulator unified log for PastaIOS (last 20 minutes)"
  if [ -n "$SIM_UDID" ]; then
    xcrun simctl spawn "$SIM_UDID" log show --last 20m --style compact \
      --predicate 'process == "PastaIOS" OR (process == "SpringBoard" AND eventMessage CONTAINS "PastaIOS") OR eventMessage CONTAINS "com.pasta.ios"' \
      > "$DIAG_DIR/simulator-pastaios.log" 2>&1
    xcrun simctl spawn "$SIM_UDID" log show --last 20m --style compact \
      --predicate 'eventMessage CONTAINS "crash" OR process == "ReportCrash" OR process == "osanalyticshelper"' \
      > "$DIAG_DIR/simulator-crash-reporter.log" 2>&1
    tail -50 "$DIAG_DIR/simulator-pastaios.log"
  fi

  echo "==> Test failures from the result bundle"
  python3 - "$DIAG_DIR/xcresult-summary.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        summary = json.load(fh)
except Exception:
    raise SystemExit(0)
for failure in summary.get("testFailures", []):
    print("FAILED", failure.get("testName"))
    print(failure.get("failureText"))
    print()
PY
  cp "$BUILD_LOG" "$TEST_LOG" "$DIAG_DIR/" 2>/dev/null
  ls -la "$DIAG_DIR"
  return 0
}

cmd_cleanup() {
  if [ -n "$SIM_UDID" ]; then
    xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
    xcrun simctl delete "$SIM_UDID" 2>/dev/null || true
  fi
  rm -f "$STATE_DIR/sim-udid"
  return 0
}

case "${1:-}" in
  create-simulator) cmd_create_simulator ;;
  resolve)          cmd_resolve ;;
  verify-release-settings) cmd_verify_release_settings ;;
  build-for-testing) cmd_build_for_testing ;;
  test)             cmd_test ;;
  summarise)        cmd_summarise ;;
  diagnostics)      cmd_diagnostics ;;
  cleanup)          cmd_cleanup ;;
  all)
    trap 'cmd_cleanup' EXIT
    cmd_create_simulator
    cmd_resolve
    cmd_build_for_testing
    STATUS=0
    cmd_test || STATUS=$?
    cmd_summarise
    if [ "$STATUS" != "0" ]; then cmd_diagnostics; fi
    exit "$STATUS"
    ;;
  *)
    echo "usage: $0 <create-simulator|resolve|verify-release-settings|build-for-testing|test|summarise|diagnostics|cleanup|all>" >&2
    exit 2
    ;;
esac
