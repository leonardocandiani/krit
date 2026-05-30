#!/usr/bin/env bash
#
# Builds, signs, and packages KRIT for macOS into a clean .dmg.
#
# Why this exists: the repo lives on an exFAT volume, which sprays ._* AppleDouble
# files that break `codesign`. And ad-hoc signatures default to a cdhash-based
# Designated Requirement that changes every rebuild, so TCC (Screen Recording)
# grants never persist. This script fixes both: it signs the FINAL bundle on an
# APFS path (/tmp) with an explicit identifier-only DR, so the grant sticks
# across rebuilds, and it rebuilds the .dmg from a clean APFS staging dir (no
# ._* leakage, no stray .VolumeIcon).
#
# No Apple account needed (ad-hoc). For public distribution, re-sign with a
# Developer ID and notarize.
#
# Usage: scripts/macos-release.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.0"
CARGO_OUT="/tmp/krit-cargo"
APP="$CARGO_OUT/release/bundle/macos/KRIT.app"
HELPER_IN_APP="$APP/Contents/Resources/KRIT Helper.app"
STAGING="/tmp/krit-dmg-staging"
DMG_OUT="$REPO/dist/KRIT_${VERSION}_aarch64.dmg"

export CARGO_TARGET_DIR="$CARGO_OUT"
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

echo "==> 1/5  tokens"
( cd "$REPO/packages/tokens" && bun run build >/dev/null )

echo "==> 2/5  native helper (Swift, release)"
( cd "$REPO/apps/helper" \
  && swift build -c release --build-path /tmp/krit-build >/dev/null \
  && bash scripts/make-app.sh /tmp/krit-build release >/dev/null )

echo "==> 3/5  tauri build (app + dmg in APFS /tmp)"
( cd "$REPO/apps/shell" && bun run tauri build >/dev/null 2>&1 )

# --- 4/5: sign the FINAL bundle on APFS with a stable, identifier-only DR ---
echo "==> 4/5  sign (ad-hoc, stable identifier DR)"
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true
dot_clean "$APP" 2>/dev/null || true

# inside-out: helper first, then the app that contains it
codesign --force --sign - --identifier "com.krit.helper" \
  -r='designated => identifier "com.krit.helper"' \
  --options runtime "$HELPER_IN_APP"
codesign --force --sign - --identifier "com.krit.app" \
  -r='designated => identifier "com.krit.app"' \
  --options runtime "$APP"

echo "    helper DR: $(codesign -d -r- "$HELPER_IN_APP" 2>&1 | grep -i designated | sed 's/^# //')"
echo "    app DR:    $(codesign -d -r- "$APP" 2>&1 | grep -i designated | sed 's/^# //')"
codesign --verify --strict "$HELPER_IN_APP" && echo "    helper verify OK"
codesign --verify --strict "$APP"           && echo "    app verify OK"

# --- 5/5: rebuild a clean .dmg from an APFS staging dir (no ._*, no .VolumeIcon) ---
echo "==> 5/5  package clean .dmg"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/KRIT.app"
ln -s /Applications "$STAGING/Applications"
xattr -cr "$STAGING" 2>/dev/null || true
find "$STAGING" -name '._*' -delete 2>/dev/null || true
mkdir -p "$REPO/dist"
rm -f "$DMG_OUT"
hdiutil create -volname "KRIT" -srcfolder "$STAGING" -ov -format UDZO "$DMG_OUT" >/dev/null
rm -rf "$STAGING"

echo ""
echo "Done: $DMG_OUT ($(du -h "$DMG_OUT" | cut -f1))"
echo "App:  $APP"
