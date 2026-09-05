#!/bin/bash
# Owner-only: make GitHub enforce the release gates on `main`.
#
# As of 2026-09-04 the only ruleset on main ("Copilot review for default
# branch") blocks deletion and force-pushes; nothing requires a pull request or
# green checks, so a red PR can be merged and anyone with push can commit
# straight to main. This script creates (or updates) a repository ruleset
# named "Release gates" that requires:
#   - a pull request (no review count; reviews are not part of the gate)
#   - the status checks ci.yml runs on every PR: "CI gate" (the always-running
#     aggregate that is green only when every suite is green and accepts a
#     skipped Playwright run only when path detection proved the landing page
#     untouched), plus "Build & Test", "iOS E2E (XCUITest)" and "Appcast &
#     Cloudflare config contract" individually. The path-filtered Playwright
#     job itself is deliberately NOT required: a skipped check never reports.
# with a bypass for repository admins so release.yml's appcast commit-back
# (scripts/ci-commit-appcast.sh, pushed with the owner's AUTO_RELEASE_TOKEN)
# can still land on main directly. Tag pushes are unaffected (branch ruleset).
#
# Rulesets need admin on the repository; the CI account (bravostation) is
# push-only, so run this as the owner:  gh auth status  →  scripts/owner-require-status-checks.sh
# Tracked as beads issue pasta-fyq.

set -euo pipefail
REPO="${REPO:-crmitchelmore/pasta}"
NAME="Release gates"

PAYLOAD=$(cat <<'JSON'
{
  "name": "Release gates",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash", "merge", "rebase"]
      }
    },
    { "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "CI gate" },
          { "context": "Build & Test" },
          { "context": "iOS E2E (XCUITest)" },
          { "context": "Appcast & Cloudflare config contract" }
        ]
      }
    }
  ]
}
JSON
)

echo "==> Checking for an existing '$NAME' ruleset on $REPO"
EXISTING_ID=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$NAME\") | .id" 2>/dev/null | head -1 || true)
if [ -n "$EXISTING_ID" ]; then
  echo "==> Updating ruleset $EXISTING_ID"
  printf '%s' "$PAYLOAD" | gh api -X PUT "repos/$REPO/rulesets/$EXISTING_ID" --input - --jq '"    \(.name): enforcement=\(.enforcement) rules=\([.rules[].type]|join(","))"'
else
  echo "==> Creating ruleset"
  printf '%s' "$PAYLOAD" | gh api -X POST "repos/$REPO/rulesets" --input - --jq '"    \(.name) (id \(.id)): enforcement=\(.enforcement) rules=\([.rules[].type]|join(","))"'
fi

echo "==> Rules now in effect on main:"
gh api "repos/$REPO/rules/branches/main" --jq '.[] | "    \(.type)\(if .parameters.required_status_checks then ": " + ([.parameters.required_status_checks[].context]|join(" | ")) else "" end)"'
echo "==> Done. Close the tracking issue:  bd close pasta-fyq"
