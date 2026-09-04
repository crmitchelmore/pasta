#!/bin/bash
# Round-trip tests for scripts/ci-verify-eddsa.sh, run by ci.yml's macOS `test`
# job so the release verifier itself cannot silently rot.
#
#   1. A file signed with a fresh Ed25519 key verifies under that key's raw
#      32-byte public key in Sparkle's SUPublicEDKey base64 form.
#   2. Tampering one byte of the file makes verification fail (exit 1).
#   3. A different key fails (exit 1).
#   4. Malformed inputs (short signature, bad base64, missing file) are tooling
#      errors (exit 2), never a false "valid".
#   5. If Sparkle's own sign_update is available, a signature it produces
#      verifies with this script and the script's math matches Sparkle's.
#
# Needs an OpenSSL 3 for key generation (same discovery as the verifier).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$ROOT/scripts/ci-verify-eddsa.sh"

for candidate in "${OPENSSL_BIN:-}" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] || continue
  if "$candidate" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then OPENSSL="$candidate"; break; fi
done
if [ -z "${OPENSSL:-}" ] && [ -n "${CI:-}" ] && command -v brew >/dev/null 2>&1; then
  echo "==> No OpenSSL 3 found; installing Homebrew openssl@3"
  brew install openssl@3 >/dev/null 2>&1 || true
  [ -x /opt/homebrew/opt/openssl@3/bin/openssl ] && OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
fi
[ -n "${OPENSSL:-}" ] || { echo "::error::ci-verify-eddsa.test: no OpenSSL 3 available"; exit 2; }
export OPENSSL_BIN="$OPENSSL"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eddsa-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; RC=0
check() { # <name> <expected-exit>  (compares against $RC from the last `run`)
  if [ "$2" = "$RC" ]; then echo "  ok   $1 (exit $RC)"; PASS=$((PASS+1)); else echo "  FAIL $1: expected exit $2, got $RC"; FAIL=$((FAIL+1)); fi
}
# Runs the command, capturing output and exit code in $RC without tripping
# `set -e` (most cases below expect a non-zero exit).
run() { set +e; "$@" >"$WORK/out.txt" 2>&1; RC=$?; set -e; }
b64() { base64 < "$1" | tr -d '\n'; }
raw_pubkey_b64() { # <private-key.pem> → Sparkle SUPublicEDKey form (raw 32 bytes, base64)
  "$OPENSSL" pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n'
}

echo "==> ci-verify-eddsa round-trip tests (openssl: $OPENSSL)"
head -c 200000 /dev/urandom > "$WORK/update.dmg"
"$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/key.pem" 2>/dev/null
"$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/other.pem" 2>/dev/null
"$OPENSSL" pkeyutl -sign -inkey "$WORK/key.pem" -rawin -in "$WORK/update.dmg" -out "$WORK/sig.bin"
SIG="$(b64 "$WORK/sig.bin")"; PUB="$(raw_pubkey_b64 "$WORK/key.pem")"; OTHER_PUB="$(raw_pubkey_b64 "$WORK/other.pem")"
[ "$(printf '%s' "$PUB" | base64 --decode | wc -c | tr -d ' ')" = "32" ] || { echo "  FAIL test setup: public key is not 32 bytes"; exit 1; }

run "$VERIFY" "$WORK/update.dmg" "$SIG" "$PUB";            check "valid signature verifies" 0
grep -q "EdDSA signature valid" "$WORK/out.txt" || { echo "  FAIL success message missing"; FAIL=$((FAIL+1)); }

cp "$WORK/update.dmg" "$WORK/tampered.dmg"; printf '\x00' | dd of="$WORK/tampered.dmg" bs=1 seek=1000 conv=notrunc 2>/dev/null
run "$VERIFY" "$WORK/tampered.dmg" "$SIG" "$PUB";          check "tampered file is INVALID" 1
grep -q "INVALID" "$WORK/out.txt" || { echo "  FAIL invalid message missing"; FAIL=$((FAIL+1)); }

run "$VERIFY" "$WORK/update.dmg" "$SIG" "$OTHER_PUB";      check "wrong public key is INVALID" 1
run "$VERIFY" "$WORK/update.dmg" "$(printf 'short' | base64)" "$PUB"; check "short signature is a tooling error" 2
run "$VERIFY" "$WORK/update.dmg" "$SIG" "not*base64!";     check "bad public key base64 is a tooling error" 2
run "$VERIFY" "$WORK/missing.dmg" "$SIG" "$PUB";           check "missing file is a tooling error" 2
run "$VERIFY" "$WORK/update.dmg";                          check "missing arguments is a usage error" 2

# Optional: prove equivalence with Sparkle's own signer when it is around.
# -L: .build may be a symlink to an external build volume. SIGN_UPDATE may be
# set explicitly (e.g. a worktree that shares another checkout's artifacts).
SIGN_UPDATE="${SIGN_UPDATE:-$(find -L "$ROOT/.build" -maxdepth 6 -type f -name sign_update 2>/dev/null | head -1 || true)}"
if [ -n "$SIGN_UPDATE" ]; then
  # Sparkle's sign_update accepts the raw 32-byte Ed25519 seed (base64) as the
  # key file; it derives the public half itself.
  "$OPENSSL" pkey -in "$WORK/key.pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' > "$WORK/sparkle.key"
  if SPARKLE_SIG="$("$SIGN_UPDATE" -p -f "$WORK/sparkle.key" "$WORK/update.dmg" 2>"$WORK/sparkle.err")"; then
    run "$VERIFY" "$WORK/update.dmg" "$SPARKLE_SIG" "$PUB"; check "Sparkle sign_update signature verifies" 0
    if [ "$SPARKLE_SIG" = "$SIG" ]; then echo "  ok   Sparkle signature is byte-identical to OpenSSL's (deterministic Ed25519)"; PASS=$((PASS+1)); else echo "  FAIL Sparkle and OpenSSL signatures differ"; FAIL=$((FAIL+1)); fi
    if "$SIGN_UPDATE" --verify -f "$WORK/sparkle.key" "$WORK/update.dmg" "$SIG" >/dev/null 2>&1; then echo "  ok   Sparkle --verify accepts OpenSSL's signature"; PASS=$((PASS+1)); else echo "  FAIL Sparkle --verify rejects OpenSSL's signature"; FAIL=$((FAIL+1)); fi
  else
    echo "  skip Sparkle sign_update rejected the hand-built key file ($(head -1 "$WORK/sparkle.err" 2>/dev/null)); equivalence not checked here"
  fi
else
  echo "  skip Sparkle sign_update not found under .build; equivalence not checked here"
fi

echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
