#!/bin/bash
# Poll App Store Connect until the build just uploaded by release-ios.yml has
# finished processing. `xcodebuild -exportArchive -destination upload` returns
# as soon as the upload is accepted; Apple then processes the binary for
# 5-30 minutes and can still reject it (processingState INVALID / FAILED)
# without anything in the workflow noticing. This closes that gap.
#
#   VALID            -> exit 0 (the build is available in TestFlight)
#   INVALID / FAILED -> exit 1 with the build attributes (::error::)
#   timeout          -> exit 1: acceptance remains unverified (do not re-upload)
#
# Usage: scripts/ci-asc-wait-for-build.sh <marketing-version> <build-number>
#
# Environment:
#   APP_STORE_CONNECT_KEY_ID      the 10-character key id            (secret)
#   APP_STORE_CONNECT_ISSUER_ID   the issuer UUID                    (secret)
#   ASC_KEY_PATH                  path to the decoded AuthKey_<id>.p8 (installed by the workflow)
#   BUNDLE_ID                     app bundle id (default com.pasta.ios) - resolved to the ASC app id
#   ASC_TIMEOUT_MINUTES           default 20
#   ASC_POLL_SECONDS              default 60
#
# The JWT is minted with openssl (ES256) and re-minted on every request so it
# never outlives the 20-minute limit App Store Connect imposes.

set -euo pipefail

VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
  echo "usage: $0 <marketing-version> <build-number>" >&2
  exit 2
fi

: "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is required}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH (path to the .p8 key) is required}"
BUNDLE_ID="${BUNDLE_ID:-com.pasta.ios}"
ASC_TIMEOUT_MINUTES="${ASC_TIMEOUT_MINUTES:-20}"
ASC_POLL_SECONDS="${ASC_POLL_SECONDS:-60}"
API="https://api.appstoreconnect.apple.com"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ES256 JWT for the App Store Connect API. openssl emits an ASN.1 DER ECDSA
# signature; JOSE wants the raw 64-byte r||s, which python extracts here
# without any third-party module.
mint_jwt() {
  local now header payload signing_input der sig
  now=$(date +%s)
  header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$APP_STORE_CONNECT_KEY_ID" | b64url)
  payload=$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' \
    "$APP_STORE_CONNECT_ISSUER_ID" "$now" "$((now + 600))" | b64url)
  signing_input="$header.$payload"
  der=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$ASC_KEY_PATH" | openssl base64 -A)
  sig=$(python3 - "$der" <<'PY'
import base64, sys
der = base64.b64decode(sys.argv[1])
# SEQUENCE { INTEGER r, INTEGER s }
assert der[0] == 0x30
i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
def read_int(pos):
    assert der[pos] == 0x02
    length = der[pos + 1]
    value = der[pos + 2:pos + 2 + length]
    return int.from_bytes(value, "big"), pos + 2 + length
r, i = read_int(i)
s, _ = read_int(i)
raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
print(base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
)
  printf '%s.%s' "$signing_input" "$sig"
}

asc_get() {
  local url="$1" token
  token=$(mint_jwt)
  curl -sS --fail-with-body --max-time 30 \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/json" \
    "$url"
}

echo "==> Resolving App Store Connect app id for $BUNDLE_ID"
APP_JSON=$(asc_get "$API/v1/apps?filter%5BbundleId%5D=$BUNDLE_ID&fields%5Bapps%5D=bundleId,name&limit=2") || {
  echo "::error::Could not query App Store Connect for app '$BUNDLE_ID'. Check APP_STORE_CONNECT_* secrets and the key's role."
  echo "$APP_JSON"
  exit 1
}
APP_ID=$(printf '%s' "$APP_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", [])
print(data[0]["id"] if data else "")')
if [ -z "$APP_ID" ]; then
  echo "::error::No App Store Connect app found with bundle id '$BUNDLE_ID'."
  echo "$APP_JSON"
  exit 1
fi
echo "    app id: $APP_ID"

QUERY="$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUILD_NUMBER&filter%5BpreReleaseVersion.version%5D=$VERSION&fields%5Bbuilds%5D=version,processingState,uploadedDate,expired,minOsVersion&sort=-uploadedDate&limit=5"
DEADLINE=$(( $(date +%s) + ASC_TIMEOUT_MINUTES * 60 ))

echo "==> Waiting up to ${ASC_TIMEOUT_MINUTES} min for build $VERSION ($BUILD_NUMBER) to finish processing (poll every ${ASC_POLL_SECONDS}s)"
ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  if RESP=$(asc_get "$QUERY"); then
    STATE=$(printf '%s' "$RESP" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", [])
if not data:
    print("NOT_FOUND")
else:
    attrs = data[0]["attributes"]
    print(attrs.get("processingState", "UNKNOWN"))
    print(json.dumps({"id": data[0]["id"], **attrs}, indent=2), file=sys.stderr)' 2> "${RUNNER_TEMP:-/tmp}/asc-build-attributes.json")
    ATTRS=$(cat "${RUNNER_TEMP:-/tmp}/asc-build-attributes.json" 2>/dev/null || true)
    echo "    [$(date -u +%H:%M:%S)] attempt $ATTEMPT: processingState=$STATE"
    case "$STATE" in
      VALID)
        echo "==> Build $VERSION ($BUILD_NUMBER) processed successfully and is available in TestFlight."
        echo "$ATTRS"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
          { echo ""; echo "App Store Connect processing: **VALID**"; echo '```json'; echo "$ATTRS"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
        fi
        exit 0
        ;;
      INVALID|FAILED)
        echo "::error::App Store Connect rejected build $VERSION ($BUILD_NUMBER): processingState=$STATE. Check the email from App Store Connect / the TestFlight tab for the reason."
        echo "$ATTRS"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
          { echo ""; echo "App Store Connect processing: **$STATE**"; echo '```json'; echo "$ATTRS"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
        fi
        exit 1
        ;;
      *) ;;  # PROCESSING or NOT_FOUND (the upload has not surfaced yet) - keep waiting
    esac
  else
    echo "    [$(date -u +%H:%M:%S)] attempt $ATTEMPT: App Store Connect request failed (transient?); will retry"
    echo "$RESP" | head -c 2000 || true
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::Could not verify App Store Connect acceptance of build $VERSION ($BUILD_NUMBER) after ${ASC_TIMEOUT_MINUTES} min (last state: ${STATE:-unknown}). The upload may still finish; check this existing build in TestFlight or rerun this polling script. Do not re-upload the same build number."
    exit 1
  fi
  sleep "$ASC_POLL_SECONDS"
done
