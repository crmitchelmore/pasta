#!/bin/bash
# Post-publish verification of a macOS release, from the point of view of a
# Sparkle client and a fresh download: the LIVE appcast and the LIVE GitHub
# release asset are the source of truth, not anything left on the runner.
#
# Checks, in order (any failure exits 1 with a ::error:: line):
#   1. https://pasta-app.com/appcast.xml parses and its top <item> has
#      sparkle:shortVersionString == <version> (retries for up to
#      APPCAST_WAIT_SECONDS while the CDN catches up).
#   2. The enclosure URL is exactly the DMG this release just published,
#      answers HTTP 200 and its Content-Length equals the enclosure `length`.
#   3. Downloading it yields a file of exactly `length` bytes.
#   4. The DMG mounts; the app inside passes `spctl --assess --type execute`
#      (Gatekeeper: Developer ID + notarization) and
#      `codesign --verify --deep --strict`, and its CFBundleShortVersionString
#      is <version> (and CFBundleVersion is sparkle:version).
#   5. The app is copied out (as a user dragging it to /Applications would) and
#      scripts/ci-launch-smoke.sh proves it initialises and quits cleanly.
#
# Usage: scripts/ci-verify-release.sh <version>            e.g. 1.5.8
#   APPCAST_URL           default https://pasta-app.com/appcast.xml
#   EXPECTED_DMG_URL      default https://github.com/crmitchelmore/pasta/releases/download/v<version>/Pasta-<version>.dmg
#   APPCAST_WAIT_SECONDS  default 300 (how long to wait for the live appcast to show <version>)
#   VERIFY_TMP            scratch dir (default RUNNER_TEMP or TMPDIR)

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
VERSION="${VERSION#v}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPCAST_URL="${APPCAST_URL:-https://pasta-app.com/appcast.xml}"
EXPECTED_DMG_URL="${EXPECTED_DMG_URL:-https://github.com/crmitchelmore/pasta/releases/download/v${VERSION}/Pasta-${VERSION}.dmg}"
APPCAST_WAIT_SECONDS="${APPCAST_WAIT_SECONDS:-300}"
VERIFY_TMP="${VERIFY_TMP:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}/pasta-verify-release"
MOUNTPOINT="$VERIFY_TMP/mnt"
rm -rf "$VERIFY_TMP"
mkdir -p "$VERIFY_TMP"

fail() {
  echo "::error::verify-release ${VERSION}: $*"
  exit 1
}

cleanup() {
  if [ -d "$MOUNTPOINT" ] && mount | grep -q " on $MOUNTPOINT "; then
    hdiutil detach "$MOUNTPOINT" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Live appcast: top item must be this version.
# ---------------------------------------------------------------------------
echo "==> [1/5] Fetching live appcast: $APPCAST_URL"
APPCAST="$VERIFY_TMP/appcast.xml"
DEADLINE=$(( $(date +%s) + APPCAST_WAIT_SECONDS ))
while :; do
  HTTP=$(curl -sS -L -o "$APPCAST" -w '%{http_code}' -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$APPCAST_URL" || echo 000)
  if [ "$HTTP" = "200" ] && TOP=$(python3 - "$APPCAST" <<'PY'
import sys, xml.etree.ElementTree as ET
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("appcast has no <item>")
enc = item.find("enclosure")
if enc is None:
    raise SystemExit("top item has no <enclosure>")
short = item.findtext("sparkle:shortVersionString", default="", namespaces=NS)
build = item.findtext("sparkle:version", default="", namespaces=NS)
print(short)
print(build)
print(enc.get("url", ""))
print(enc.get("length", ""))
print(enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", ""))
PY
  ); then
    TOP_SHORT=$(printf '%s\n' "$TOP" | sed -n 1p)
    TOP_BUILD=$(printf '%s\n' "$TOP" | sed -n 2p)
    TOP_URL=$(printf '%s\n' "$TOP" | sed -n 3p)
    TOP_LENGTH=$(printf '%s\n' "$TOP" | sed -n 4p)
    TOP_SIG=$(printf '%s\n' "$TOP" | sed -n 5p)
    if [ "$TOP_SHORT" = "$VERSION" ]; then
      break
    fi
    echo "    appcast top item is $TOP_SHORT, waiting for $VERSION (CDN propagation)..."
  else
    echo "    appcast fetch/parse failed (HTTP $HTTP), retrying..."
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "--- appcast as served:"; head -40 "$APPCAST" 2>/dev/null || true
    fail "live appcast top item is '${TOP_SHORT:-unparseable}' after ${APPCAST_WAIT_SECONDS}s; expected ${VERSION}. Sparkle clients will not see this release."
  fi
  sleep 15
done
echo "✓ appcast top item: version $TOP_SHORT (build $TOP_BUILD), enclosure $TOP_URL ($TOP_LENGTH bytes)"
[ -n "$TOP_LENGTH" ] && [[ "$TOP_LENGTH" =~ ^[0-9]+$ ]] || fail "enclosure length '$TOP_LENGTH' is not a number"
[ -n "$TOP_SIG" ] || fail "enclosure has no sparkle:edSignature; Sparkle will refuse the update"

# ---------------------------------------------------------------------------
# 2. Enclosure URL is the just-published DMG and is actually downloadable.
# ---------------------------------------------------------------------------
echo "==> [2/5] Checking enclosure URL"
[ "$TOP_URL" = "$EXPECTED_DMG_URL" ] || fail "enclosure url is '$TOP_URL', expected '$EXPECTED_DMG_URL'"
HEADERS="$VERIFY_TMP/dmg-headers.txt"
HEAD_CODE=$(curl -sS -I -L -o "$HEADERS" -w '%{http_code}' "$TOP_URL" || echo 000)
[ "$HEAD_CODE" = "200" ] || { cat "$HEADERS" 2>/dev/null || true; fail "HEAD $TOP_URL returned HTTP $HEAD_CODE (expected 200). Is the GitHub release published, not draft?"; }
# curl -I -L writes every hop's headers; the final hop's Content-Length is the asset's.
CONTENT_LENGTH=$(grep -i '^content-length:' "$HEADERS" | tail -1 | awk '{print $2}' | tr -d '\r')
[ "$CONTENT_LENGTH" = "$TOP_LENGTH" ] || fail "Content-Length of $TOP_URL is '${CONTENT_LENGTH:-missing}', appcast enclosure length is $TOP_LENGTH. Sparkle would abort the download."
echo "✓ HTTP 200, Content-Length $CONTENT_LENGTH matches enclosure length"

# ---------------------------------------------------------------------------
# 3. Download and size-check.
# ---------------------------------------------------------------------------
echo "==> [3/5] Downloading DMG"
DMG="$VERIFY_TMP/$(basename "$TOP_URL")"
GET_CODE=$(curl -sS -L -o "$DMG" -w '%{http_code}' "$TOP_URL" || echo 000)
[ "$GET_CODE" = "200" ] || fail "GET $TOP_URL returned HTTP $GET_CODE"
ACTUAL_SIZE=$(stat -f%z "$DMG")
[ "$ACTUAL_SIZE" = "$TOP_LENGTH" ] || fail "downloaded DMG is $ACTUAL_SIZE bytes, appcast says $TOP_LENGTH"
echo "✓ downloaded $(basename "$DMG"): $ACTUAL_SIZE bytes, sha256 $(shasum -a 256 "$DMG" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 4. Mount; Gatekeeper + codesign + version of the app inside.
# ---------------------------------------------------------------------------
echo "==> [4/5] Mounting DMG and assessing the app"
mkdir -p "$MOUNTPOINT"
hdiutil attach "$DMG" -mountpoint "$MOUNTPOINT" -nobrowse -readonly -noautoopen >/dev/null || fail "hdiutil could not attach $DMG"
APP_IN_DMG=$(find "$MOUNTPOINT" -maxdepth 1 -name '*.app' -print -quit)
[ -n "$APP_IN_DMG" ] || fail "no .app found at the root of the DMG"
echo "    app: $APP_IN_DMG"

echo "    stapler validate (notarization ticket on the DMG):"
xcrun stapler validate "$DMG" || fail "DMG has no valid notarization ticket stapled"

echo "    spctl --assess --type execute:"
SPCTL_OUT=$(spctl --assess --type execute --verbose=4 "$APP_IN_DMG" 2>&1) || { echo "$SPCTL_OUT"; fail "Gatekeeper rejects the app (spctl): $SPCTL_OUT"; }
echo "    $SPCTL_OUT"
echo "$SPCTL_OUT" | grep -q "accepted" || fail "spctl did not report 'accepted': $SPCTL_OUT"

echo "    codesign --verify --deep --strict:"
codesign --verify --deep --strict --verbose=2 "$APP_IN_DMG" || fail "codesign --verify --deep --strict failed on the shipped app"

INFO="$APP_IN_DMG/Contents/Info.plist"
APP_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
APP_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")
APP_FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO" 2>/dev/null || echo missing)
[ "$APP_SHORT" = "$VERSION" ] || fail "shipped app is CFBundleShortVersionString $APP_SHORT, expected $VERSION"
[ "$APP_BUILD" = "$TOP_BUILD" ] || fail "shipped app is CFBundleVersion $APP_BUILD but appcast sparkle:version is $TOP_BUILD; Sparkle would offer the update forever"
[ "$APP_FEED" = "$APPCAST_URL" ] || fail "shipped app's SUFeedURL is '$APP_FEED', expected '$APPCAST_URL'"
echo "✓ notarized, Gatekeeper-accepted, signature intact, version $APP_SHORT ($APP_BUILD), SUFeedURL $APP_FEED"

# ---------------------------------------------------------------------------
# 5. Launch-readiness smoke on a copy (what the user's /Applications holds).
# ---------------------------------------------------------------------------
echo "==> [5/5] Launch-readiness smoke test"
INSTALL_DIR="$VERIFY_TMP/Applications"
mkdir -p "$INSTALL_DIR"
ditto "$APP_IN_DMG" "$INSTALL_DIR/$(basename "$APP_IN_DMG")"
hdiutil detach "$MOUNTPOINT" >/dev/null || hdiutil detach "$MOUNTPOINT" -force >/dev/null
SMOKE_TMP="$VERIFY_TMP" "$SCRIPT_DIR/ci-launch-smoke.sh" "$INSTALL_DIR/$(basename "$APP_IN_DMG")" \
  || fail "the published app failed the launch-readiness smoke test"

echo ""
echo "==> ✅ Release $VERSION verified end-to-end from the live appcast and GitHub release."
