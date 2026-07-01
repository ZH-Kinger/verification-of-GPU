#!/usr/bin/env bash
# Fetch the Ubuntu Server 24.04.4 live ISO (+ checksums) into downloads/iso/ and
# verify SHA256. This ISO is only needed to (re)flash the boot USB, not at run time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/downloads/iso"
mkdir -p "$DEST"

ISO="ubuntu-24.04.4-live-server-amd64.iso"
BASE="https://releases.ubuntu.com/24.04"
EXPECT_SHA="e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"

curl -fL --retry 3 -o "$DEST/SHA256SUMS"     "$BASE/SHA256SUMS"
curl -fL --retry 3 -o "$DEST/SHA256SUMS.gpg" "$BASE/SHA256SUMS.gpg" || true

if [ ! -s "$DEST/$ISO" ]; then
  echo "Downloading $ISO (~3.2 GB)..."
  curl -fL --retry 3 -C - -o "$DEST/$ISO" "$BASE/$ISO"
else
  echo "[skip] $ISO already present"
fi

echo "Verifying SHA256..."
actual="$(sha256sum "$DEST/$ISO" | awk '{print $1}')"
if [ "$actual" = "$EXPECT_SHA" ]; then
  echo "OK: $ISO SHA256 matches ($EXPECT_SHA)"
else
  echo "MISMATCH: expected $EXPECT_SHA got $actual" >&2
  exit 1
fi
