#!/usr/bin/env bash
# Usage: ci-stapler.sh <staple|validate> <file>
# Runs `xcrun stapler` with retries. Stapler fetches and checks tickets through
# Apple's CloudKit ticket service, which drops connections now and then
# (NSURLError -1005, "Error 68"). A genuinely missing ticket still fails after
# the final attempt.
set -euo pipefail

action="${1:?usage: ci-stapler.sh <staple|validate> <file>}"
file="${2:?usage: ci-stapler.sh <staple|validate> <file>}"
attempts="${STAPLER_ATTEMPTS:-4}"
delay="${STAPLER_RETRY_DELAY:-15}"
stapler="${STAPLER_BIN:-xcrun stapler}"

case "$action" in
  staple|validate) ;;
  *) echo "::error::unknown stapler action: $action" >&2; exit 2 ;;
esac

for ((i = 1; i <= attempts; i++)); do
  if $stapler "$action" "$file"; then
    exit 0
  else
    status=$?
  fi
  if ((i < attempts)); then
    echo "::warning::stapler $action failed for $file (exit $status, attempt $i/$attempts); retrying in ${delay}s"
    sleep "$delay"
  fi
done

echo "::error::stapler $action failed for $file after $attempts attempts (last exit $status)"
exit "$status"
