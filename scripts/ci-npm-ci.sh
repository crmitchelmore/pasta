#!/bin/bash
# `npm ci` for the landing-page jobs, with bounded fetches and one retry.
#
# On 2026-09-04 a plain `npm ci` stalled for the whole 5-minute job timeout on
# two concurrent main runs (a transient registry hiccup); the cancelled job
# blocked auto-release and cost a release cycle. Registry stalls are the one
# failure here that a retry genuinely fixes, so cap each attempt and try twice.
#
# Usage: scripts/ci-npm-ci.sh            (run from the package directory)
#   NPM_CI_ATTEMPT_TIMEOUT  seconds per attempt (default 180)
#   NPM_CI_ATTEMPTS         number of attempts (default 2)

set -euo pipefail

ATTEMPT_TIMEOUT="${NPM_CI_ATTEMPT_TIMEOUT:-180}"
ATTEMPTS="${NPM_CI_ATTEMPTS:-2}"

# GNU timeout is on Ubuntu runners; macOS only has it via coreutils (gtimeout).
# Without either, run unbounded (npm's own --fetch-timeout still applies).
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

npm_ci() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$ATTEMPT_TIMEOUT" npm ci --no-audit --no-fund --fetch-timeout=60000 --fetch-retries=3
  else
    npm ci --no-audit --no-fund --fetch-timeout=60000 --fetch-retries=3
  fi
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  rc=0
  npm_ci || rc=$?
  if [ "$rc" = "0" ]; then
    exit 0
  fi
  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    echo "::warning::npm ci attempt ${attempt} failed or stalled (exit ${rc}); retrying"
    npm cache verify >/dev/null 2>&1 || true
  else
    echo "::error::npm ci failed after ${ATTEMPTS} attempts (last exit ${rc})"
    exit "$rc"
  fi
done
