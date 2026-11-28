#!/bin/bash
# Generate Sparkle appcast.xml from GitHub release
# Usage: ./scripts/generate-appcast.sh <version> <build-number> <dmg-path> <private-key-base64> [release-notes-html]

set -e

VERSION="$1"
BUILD_NUMBER="$2"
DMG_PATH="$3"
PRIVATE_KEY_BASE64="$4"
RELEASE_NOTES_HTML_PATH="${5:-}"

if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ] || [ -z "$DMG_PATH" ] || [ -z "$PRIVATE_KEY_BASE64" ]; then
    echo "Usage: $0 <version> <build-number> <dmg-path> <private-key-base64>"
    exit 1
fi

# Get file info
FILE_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat --format=%s "$DMG_PATH")
PUB_DATE=$(date -R)
DMG_NAME=$(basename "$DMG_PATH")

# Private scratch directory for the key, signing output and any downloaded tools
WORK_DIR=$(mktemp -d)
PRIVATE_KEY_FILE="$WORK_DIR/private-key"
# Ensure private key and scratch files are cleaned up on exit
trap 'rm -rf "$WORK_DIR"' EXIT

# The Sparkle private key is a base64-encoded string
# sign_update expects the raw string, NOT base64-decoded bytes
echo "$PRIVATE_KEY_BASE64" > "$PRIVATE_KEY_FILE"
echo "Private key written" >&2

# Find Sparkle's sign_update tool
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
if [ -n "$SIGN_UPDATE" ]; then
    if [ ! -x "$SIGN_UPDATE" ]; then
        echo "ERROR: configured Sparkle sign_update is missing or not executable: $SIGN_UPDATE" >&2
        exit 1
    fi
elif [ -f ".build/artifacts/sparkle/Sparkle/bin/sign_update" ]; then
    SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
elif command -v sign_update &> /dev/null; then
    SIGN_UPDATE="sign_update"
else
    echo "Warning: sign_update not found, downloading Sparkle tools..." >&2
    SPARKLE_VERSION="2.8.1"
    # SHA-256 of the official Sparkle-2.8.1.tar.xz release asset (matches GitHub's published asset digest).
    SPARKLE_SHA256="5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be"
    SPARKLE_ARCHIVE="$WORK_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz"
    curl -fsSL --proto '=https' -o "$SPARKLE_ARCHIVE" \
        "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    ACTUAL_SHA256=$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]; then
        echo "ERROR: Sparkle ${SPARKLE_VERSION} archive checksum mismatch (expected $SPARKLE_SHA256, got $ACTUAL_SHA256)" >&2
        exit 1
    fi
    mkdir "$WORK_DIR/sparkle"
    tar xJf "$SPARKLE_ARCHIVE" -C "$WORK_DIR/sparkle"
    SIGN_UPDATE="$WORK_DIR/sparkle/bin/sign_update"
fi

# Generate EdDSA signature
echo "Running sign_update..." >&2
echo "SIGN_UPDATE path: $SIGN_UPDATE" >&2

# Run sign_update and capture output
set +e
"$SIGN_UPDATE" --ed-key-file "$PRIVATE_KEY_FILE" "$DMG_PATH" > "$WORK_DIR/sign_output.txt" 2>&1
SIGN_EXIT_CODE=$?
set -e

echo "sign_update exit code: $SIGN_EXIT_CODE" >&2
echo "sign_update output:" >&2
cat "$WORK_DIR/sign_output.txt" >&2

SIGNATURE=$(grep "sparkle:edSignature" "$WORK_DIR/sign_output.txt" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/' || true)

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to generate signature" >&2
    exit 1
fi

# GitHub release download URL
ENCODED_DMG_NAME=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$DMG_NAME")
DOWNLOAD_URL="https://github.com/crmitchelmore/pasta/releases/download/${DOWNLOAD_TAG:-v${VERSION}}/${ENCODED_DMG_NAME}"

# Generate appcast XML
# IMPORTANT: sparkle:version MUST match CFBundleVersion (the build number)
# sparkle:shortVersionString is the human-readable marketing version
cat << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Pasta Updates</title>
    <link>https://github.com/crmitchelmore/pasta/releases/latest/download/appcast.xml</link>
    <description>Most recent updates to Pasta</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <pubDate>${PUB_DATE}</pubDate>
      $(if [ -n "$RELEASE_NOTES_HTML_PATH" ] && [ -s "$RELEASE_NOTES_HTML_PATH" ]; then
          printf '<description><![CDATA[\n%s\n      ]]></description>' "$(cat "$RELEASE_NOTES_HTML_PATH")"
        fi)
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${SIGNATURE}"
        length="${FILE_SIZE}"
        type="application/octet-stream"/>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
EOF
