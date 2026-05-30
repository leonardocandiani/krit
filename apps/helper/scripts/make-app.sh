#!/usr/bin/env bash
#
# Packages the krit-helper executable into a minimal "KRIT Helper.app" bundle.
#
# The bundle is required because ScreenCaptureKit/TCC ties the Screen Recording
# permission to an app with a stable Info.plist and bundle identifier — a bare
# binary does not appear correctly in System Settings.
#
# Ad-hoc signs the bundle with a stable identifier (required for Screen
# Recording / TCC to persist). For public distribution, re-sign with a
# Developer ID and notarize afterwards.
#
# Usage:
#   ./scripts/make-app.sh [build-path]
#
# Defaults to /tmp/krit-build (outside the project volume, which is often full).
# Pass a different path if you compiled elsewhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_PATH="${1:-/tmp/krit-build}"
CONFIG="${2:-debug}"
BINARY="$BUILD_PATH/$CONFIG/krit-helper"

APP_NAME="KRIT Helper"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found at: $BINARY" >&2
  echo "Build first with:" >&2
  echo "  swift build --build-path $BUILD_PATH" >&2
  exit 1
fi

echo "Packaging $APP_NAME.app ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Executable inside the bundle is named "krit-helper" (== CFBundleExecutable).
cp "$BINARY" "$MACOS_DIR/krit-helper"
chmod +x "$MACOS_DIR/krit-helper"

# Native sounds (.caf) — the shutter plays via AVAudioPlayer at capture time.
# KritSounds looks first in Bundle.main/Resources.
SOUNDS_SRC="$PROJECT_DIR/../../assets/sounds"
if [[ -d "$SOUNDS_SRC" ]]; then
  for s in capture copy save record-start record-stop error pin toggle launch; do
    [[ -f "$SOUNDS_SRC/$s.caf" ]] && cp "$SOUNDS_SRC/$s.caf" "$RESOURCES_DIR/$s.caf"
  done
  echo ".caf sounds copied to Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>KRIT Helper</string>
    <key>CFBundleDisplayName</key>
    <string>KRIT Helper</string>
    <key>CFBundleExecutable</key>
    <string>krit-helper</string>
    <key>CFBundleIdentifier</key>
    <string>com.krit.helper</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>KRIT needs screen access to capture screenshots.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cat > "$APP_DIR/Contents/PkgInfo" <<'PKG'
APPL????
PKG

# Remove AppleDouble files (._*) created by the volume filesystem on copy.
find "$APP_DIR" -name '._*' -delete 2>/dev/null || true
dot_clean "$APP_DIR" 2>/dev/null || true

# Ad-hoc sign with an EXPLICIT designated requirement keyed only on the bundle
# identifier. This is what makes Screen Recording (TCC) persist: by default an
# ad-hoc signature's DR is a raw cdhash that changes every recompile, so each
# grant is orphaned and CGPreflightScreenCaptureAccess stays false forever. With
# `-r='designated => identifier "com.krit.helper"'` the DR is the identifier
# alone, stable across rebuilds — grant once, keep it. No Apple account needed.
# codesign must run on an APFS/HFS+ path; on exFAT the ._* AppleDouble files
# break it (see scripts/macos-release.sh, which signs the final bundle in /tmp).
SIGN_REQ='designated => identifier "com.krit.helper"'
codesign --force --sign - \
  --identifier "com.krit.helper" \
  -r="$SIGN_REQ" \
  --options runtime \
  "$APP_DIR" 2>/dev/null \
  && echo "Signed (ad-hoc, stable DR: identifier com.krit.helper)." \
  || echo "WARN: codesign failed (exFAT? sign in /tmp via macos-release.sh)."

echo "Done: $APP_DIR"
echo
echo "To run:"
echo "  open \"$APP_DIR\""
echo
echo "On first launch, grant Screen Recording in:"
echo "  System Settings > Privacy & Security > Screen Recording"
