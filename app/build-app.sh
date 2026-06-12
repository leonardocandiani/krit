#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KRIT"
ENTITLEMENTS="$SCRIPT_DIR/Krit.entitlements"
BUILD_PATH="/tmp/krit-app-build"

# Assemble and sign the bundle on an APFS path (BUILD_PATH), never inside the
# source tree. This keeps build artifacts out of the repo and, critically,
# avoids exFAT volumes whose ._* AppleDouble files break codesign. The signed
# bundle is copied to /Applications at the end.
APP_BUNDLE="$BUILD_PATH/$APP_NAME.app"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

SIGN_IDENTITY="${KRIT_CODESIGN_IDENTITY:--}"
TIMESTAMP_MODE="${KRIT_CODESIGN_TIMESTAMP:-auto}"

echo "▶ Building $APP_NAME (release)…"
cd "$SCRIPT_DIR"
# Build ONLY the app target here. The "krit" CLI product collides with the "Krit"
# app binary in a shared release dir on case-insensitive volumes, so it is built
# separately below into its own path.
swift build -c release --product KritApp --build-path "$BUILD_PATH" 2>&1

# The CLI product is named "krit", which collides with the "Krit" app binary in
# the same release directory on case-insensitive volumes (APFS default, exFAT).
# Build it into a dedicated path so both binaries materialize.
CLI_BUILD_PATH="$BUILD_PATH-cli"
echo "▶ Building krit CLI (release)…"
swift build -c release --product krit --build-path "$CLI_BUILD_PATH" 2>&1

# SPM places the binary under a platform-arch subdirectory when --build-path is explicit.
# Probe both locations so the script works on Intel and Apple Silicon alike.
BINARY="$BUILD_PATH/release/KritApp"
if [ ! -f "$BINARY" ]; then
    BINARY="$(find "$BUILD_PATH" -maxdepth 3 -name "KritApp" -type f -path "*/release/KritApp" | grep -v dSYM | head -1)"
fi
if [ ! -f "$BINARY" ]; then
    echo "✗ Build failed — binary not found under $BUILD_PATH"
    exit 1
fi

# Locate the krit CLI binary from its dedicated build path. Probe the flat release
# dir first, then the arch-subdirectory layout.
CLI_BINARY="$CLI_BUILD_PATH/release/krit"
if [ ! -f "$CLI_BINARY" ]; then
    CLI_BINARY="$(find "$CLI_BUILD_PATH" -maxdepth 3 -name "krit" -type f -path "*/release/krit" | grep -v dSYM | head -1)"
fi
if [ ! -f "$CLI_BINARY" ]; then
    echo "✗ Build failed — krit CLI binary not found under $BUILD_PATH"
    exit 1
fi

echo "▶ Assembling .app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
# The CLI lives in Contents/Helpers, NOT Contents/MacOS: the app binary is "KRIT"
# and the CLI is "krit", which are the SAME path on case-insensitive volumes
# (APFS default). Putting krit in MacOS/ would overwrite the app's main binary.
mkdir -p "$APP_BUNDLE/Contents/Helpers"

cp "$BINARY"                "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$CLI_BINARY"            "$APP_BUNDLE/Contents/Helpers/krit"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Stamp the bundle with the build time so the installed app is identifiable:
#   defaults read /Applications/KRIT.app/Contents/Info CFBundleVersion
# answers "which build am I actually running?" without guessing.
BUILD_STAMP="$(date +%Y%m%d.%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_STAMP" "$APP_BUNDLE/Contents/Info.plist"
echo "▶ Build stamp: $BUILD_STAMP"

# Copy icon into bundle (if present)
if [ -f "$SCRIPT_DIR/Branding/KRIT.icns" ]; then
    cp "$SCRIPT_DIR/Branding/KRIT.icns" "$APP_BUNDLE/Contents/Resources/KRIT.icns"
fi

if [ -f "$SCRIPT_DIR/PrivacyInfo.xcprivacy" ]; then
    cp "$SCRIPT_DIR/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
fi

if [ -f "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" ]; then
    cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
fi

# Copy SPM-generated resource bundle (capture sound, etc.) if present
# Probe flat and arch-subdirectory layouts
SPM_RESOURCE_BUNDLE="$(find "$BUILD_PATH" -maxdepth 4 -name "Krit_KritKit.bundle" -type d | head -1)"
if [ -d "$SPM_RESOURCE_BUNDLE" ]; then
    cp -R "$SPM_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Strip extended attributes / AppleDouble residue before signing. Files copied
# from an exFAT source can carry xattrs that make codesign choke.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -name '._*' -delete 2>/dev/null || true
command -v dot_clean >/dev/null && dot_clean "$APP_BUNDLE" 2>/dev/null || true

# The krit CLI is a separate Mach-O sitting in Contents/Helpers/ (NOT MacOS/, which
# would collide with the "KRIT" app binary on case-insensitive volumes — see above).
# Signing the bundle does not reach loose nested executables, so sign it on its own
# first (same identity; its own identifier). The bundle sign below seals over it.
echo "▶ Signing nested krit CLI…"
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --identifier "com.krit.cli" \
        --options runtime --timestamp "$APP_BUNDLE/Contents/Helpers/krit"
else
    codesign --force --sign "$SIGN_IDENTITY" --identifier "com.krit.cli" \
        --options runtime "$APP_BUNDLE/Contents/Helpers/krit"
fi

echo "▶ Signing with identity: $SIGN_IDENTITY"

if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    # Developer ID path — use timestamp, no custom -r needed
    SIGN_ARGS=(
        --force
        --sign "$SIGN_IDENTITY"
        --identifier "com.krit.app"
        --options runtime
        --timestamp
        --entitlements "$ENTITLEMENTS"
    )
    codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
else
    # Ad-hoc / self-signed — pin the Designated Requirement so TCC entry
    # for Screen Recording survives rebuilds without re-prompting
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --identifier "com.krit.app" \
        -r='designated => identifier "com.krit.app"' \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        "$APP_BUNDLE"
fi

echo "▶ Copying to /Applications…"
APPS_DEST="/Applications/$APP_NAME.app"
rm -rf "$APPS_DEST"
cp -R "$APP_BUNDLE" "$APPS_DEST"

echo ""
echo "✓ Done!  KRIT.app deployed to /Applications."
echo "  Launch it from /Applications."
echo ""
echo "  First launch: grant Screen Recording permission when prompted"
echo "  (System Settings → Privacy & Security → Screen Recording)"
