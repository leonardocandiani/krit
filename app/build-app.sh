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

# Universal binary: build for BOTH Apple Silicon (arm64) and Intel (x86_64) so
# the shipped app runs natively on every Mac. A multi-arch `swift build --arch …`
# delegates to xcbuild, which requires a FULL Xcode toolchain — the bare Command
# Line Tools cannot emit multi-arch slices (they lack XCBuild.framework).
#   KRIT_ARCHS unset → universal (arm64 x86_64)  [default]
#   KRIT_ARCHS="arm64" → single arch (faster; still routes through xcbuild)
#   KRIT_ARCHS=""      → plain `swift build`, no --arch (host arch, llbuild path)
# The `-` (not `:-`) is deliberate: an explicitly EMPTY KRIT_ARCHS must survive as
# empty so the no-`--arch` build stays reachable; `:-` would overwrite it.
KRIT_ARCHS="${KRIT_ARCHS-arm64 x86_64}"
ARCH_FLAGS=()
for _a in $KRIT_ARCHS; do ARCH_FLAGS+=(--arch "$_a"); done

# Fail loudly if a shipped Mach-O is missing one of the requested arch slices —
# a half-universal binary that silently dropped Intel is exactly the bug this
# script exists to prevent.
assert_archs() {
    local label="$1" path="$2"
    local got; got="$(lipo -archs "$path" 2>/dev/null)"
    local want
    for want in $KRIT_ARCHS; do
        case " $got " in
            *" $want "*) ;;
            *) echo "✗ $label is missing arch '$want' (has: ${got:-none}) — $path"; exit 1;;
        esac
    done
    echo "▶ $label archs: $got"
}

echo "▶ Building $APP_NAME (release, archs: $KRIT_ARCHS)…"
cd "$SCRIPT_DIR"
# Build ONLY the app target here. The "krit" CLI product collides with the "Krit"
# app binary in a shared release dir on case-insensitive volumes, so it is built
# separately below into its own path.
swift build -c release --product KritApp "${ARCH_FLAGS[@]}" --build-path "$BUILD_PATH" 2>&1

# The CLI product is named "krit", which collides with the "Krit" app binary in
# the same release directory on case-insensitive volumes (APFS default, exFAT).
# Build it into a dedicated path so both binaries materialize.
CLI_BUILD_PATH="$BUILD_PATH-cli"
echo "▶ Building krit CLI (release, archs: $KRIT_ARCHS)…"
swift build -c release --product krit "${ARCH_FLAGS[@]}" --build-path "$CLI_BUILD_PATH" 2>&1

# Locating the product binary has to survive THREE SPM output layouts:
#   - flat llbuild:        $BUILD_PATH/release/KritApp
#   - arch-triple llbuild: $BUILD_PATH/<triple>/release/KritApp   (explicit --build-path)
#   - multi-arch xcbuild:  $BUILD_PATH/apple/Products/Release/KritApp   (--arch a --arch b)
# A single case-insensitive `-ipath "*/release/KritApp"` matches all three (the
# xcbuild layout capitalizes "Release"). dSYM bundles carry a same-named binary,
# so exclude them.
BINARY="$BUILD_PATH/release/KritApp"
if [ ! -f "$BINARY" ]; then
    BINARY="$(find "$BUILD_PATH" -name "KritApp" -type f -ipath "*/release/KritApp" ! -path "*.dSYM/*" 2>/dev/null | head -1)"
fi
if [ ! -f "$BINARY" ]; then
    echo "✗ Build failed — binary not found under $BUILD_PATH"
    exit 1
fi
assert_archs "KritApp" "$BINARY"

# Locate the krit CLI binary from its dedicated build path (same three layouts).
CLI_BINARY="$CLI_BUILD_PATH/release/krit"
if [ ! -f "$CLI_BINARY" ]; then
    CLI_BINARY="$(find "$CLI_BUILD_PATH" -name "krit" -type f -ipath "*/release/krit" ! -path "*.dSYM/*" 2>/dev/null | head -1)"
fi
if [ ! -f "$CLI_BINARY" ]; then
    echo "✗ Build failed — krit CLI binary not found under $BUILD_PATH"
    exit 1
fi
assert_archs "krit CLI" "$CLI_BINARY"

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

# Copy SPM-generated resource bundle (capture sound, etc.) if present.
# No maxdepth: the multi-arch xcbuild layout nests it under apple/Products/Release/.
SPM_RESOURCE_BUNDLE="$(find "$BUILD_PATH" -name "Krit_KritKit.bundle" -type d 2>/dev/null | head -1)"
if [ -d "$SPM_RESOURCE_BUNDLE" ]; then
    cp -R "$SPM_RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Embed Sparkle.framework (auto-update). SPM links the app against the binary
# xcframework artifact whose install name is @rpath/Sparkle.framework/…, so the
# bundle must carry the framework and the binary an rpath that reaches it.
# Sparkle's xcframework ships a UNIVERSAL macOS slice (macos-arm64_x86_64); prefer
# it explicitly so a multi-arch KRIT never embeds a single-arch updater. Artifacts
# live next to whichever build resolved them: the explicit --build-path dirs, or
# the default .build/ when a no-build-path resolve populated them.
SPARKLE_FRAMEWORK=""
for _root in "$BUILD_PATH/artifacts" "$CLI_BUILD_PATH/artifacts" "$SCRIPT_DIR/.build/artifacts"; do
    [ -d "$_root" ] || continue
    SPARKLE_FRAMEWORK="$(find "$_root" -name "Sparkle.framework" -type d -ipath "*macos-arm64_x86_64*" 2>/dev/null | head -1)"
    [ -n "$SPARKLE_FRAMEWORK" ] && break
    SPARKLE_FRAMEWORK="$(find "$_root" -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
    [ -n "$SPARKLE_FRAMEWORK" ] && break
done
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "✗ Sparkle.framework not found in build artifacts"
    exit 1
fi
echo "▶ Embedding Sparkle.framework…"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
# Assert the embedded Sparkle carries every requested slice — a universal app with
# an arm64-only updater would crash on Intel the moment it checked for updates.
SPARKLE_BIN="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
[ -f "$SPARKLE_BIN" ] && assert_archs "Sparkle.framework" "$SPARKLE_BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

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

# Sparkle ships signed by the Sparkle project; re-sign every nested executable
# with our identity (inside-out, per Sparkle's sanctioned re-signing order) so
# the whole bundle carries one identity and library validation stays coherent.
echo "▶ Re-signing embedded Sparkle.framework…"
SPARKLE_IN_BUNDLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
TS_FLAG=()
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    TS_FLAG=(--timestamp)
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime "${TS_FLAG[@]}" \
    "$SPARKLE_IN_BUNDLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "${TS_FLAG[@]}" \
    --preserve-metadata=entitlements \
    "$SPARKLE_IN_BUNDLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "${TS_FLAG[@]}" \
    "$SPARKLE_IN_BUNDLE/Versions/B/Autoupdate"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "${TS_FLAG[@]}" \
    "$SPARKLE_IN_BUNDLE/Versions/B/Updater.app"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "${TS_FLAG[@]}" \
    "$SPARKLE_IN_BUNDLE"

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
