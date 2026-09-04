#!/bin/bash
# Verify a Sparkle EdDSA update signature the way a Sparkle client does.
#
# Sparkle 2 signs the update archive's raw bytes with Ed25519 (`sign_update`)
# and publishes the signature as `sparkle:edSignature` (base64, 64 bytes). The
# client checks it against `SUPublicEDKey` from its own Info.plist (base64, the
# 32-byte raw public key). A mismatch is silent for users: every installed copy
# simply refuses the update. This script performs exactly that check with an
# OpenSSL 3 (`pkeyutl -rawin`); macOS's bundled LibreSSL cannot, so Homebrew's
# openssl@3 is used when present. Set OPENSSL_BIN to point at another.
#
# Usage: scripts/ci-verify-eddsa.sh <update-file> <signature-base64> <public-key-base64>
# Exit:  0 signature valid · 1 signature INVALID · 2 usage or tooling problem

set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: $0 <update-file> <signature-base64> <public-key-base64>" >&2
  exit 2
fi
FILE="$1"; SIG_B64="$2"; PUB_B64="$3"
[ -f "$FILE" ] || { echo "::error::ci-verify-eddsa: no such file: $FILE" >&2; exit 2; }

find_openssl() {
  local candidate
  for candidate in "${OPENSSL_BIN:-}" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}
OPENSSL="$(find_openssl)" || {
  echo "::error::ci-verify-eddsa: no OpenSSL with Ed25519 'pkeyutl -rawin' found (macOS LibreSSL lacks it). Install Homebrew openssl@3 or set OPENSSL_BIN." >&2
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eddsa.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# base64 -d on macOS accepts -d (12.3+) and --decode; -D is the legacy spelling.
decode_b64() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }

decode_b64 "$SIG_B64" > "$WORK/sig.bin" || { echo "::error::ci-verify-eddsa: signature is not valid base64" >&2; exit 2; }
decode_b64 "$PUB_B64" > "$WORK/pub.raw" || { echo "::error::ci-verify-eddsa: public key is not valid base64" >&2; exit 2; }
SIG_LEN=$(stat -f%z "$WORK/sig.bin" 2>/dev/null || stat -c%s "$WORK/sig.bin")
PUB_LEN=$(stat -f%z "$WORK/pub.raw" 2>/dev/null || stat -c%s "$WORK/pub.raw")
[ "$SIG_LEN" = "64" ] || { echo "::error::ci-verify-eddsa: signature decodes to $SIG_LEN bytes, Ed25519 needs 64" >&2; exit 2; }
[ "$PUB_LEN" = "32" ] || { echo "::error::ci-verify-eddsa: public key decodes to $PUB_LEN bytes, Ed25519 needs 32" >&2; exit 2; }

# Wrap the raw key in the X.509 SubjectPublicKeyInfo header for Ed25519
# (OID 1.3.101.112) so OpenSSL can load it: 302a300506032b6570032100 || key.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; cat "$WORK/pub.raw"; } > "$WORK/pub.der"
"$OPENSSL" pkey -pubin -inform DER -in "$WORK/pub.der" -outform PEM -out "$WORK/pub.pem" 2>/dev/null \
  || { echo "::error::ci-verify-eddsa: public key is not a loadable Ed25519 key" >&2; exit 2; }

if "$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin -in "$FILE" -sigfile "$WORK/sig.bin" >/dev/null 2>&1; then
  echo "✓ EdDSA signature valid for $(basename "$FILE") under public key ${PUB_B64:0:12}…"
  exit 0
fi
echo "::error::ci-verify-eddsa: EdDSA signature is INVALID for $(basename "$FILE") under public key ${PUB_B64:0:12}… — Sparkle clients would refuse this update" >&2
exit 1
