#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="KRIT"
ENTITLEMENTS="$SCRIPT_DIR/Krit.entitlements"
APP_DESTINATION="${KRIT_APP_DESTINATION:-/Applications/$APP_NAME.app}"

usage() {
    printf '%s\n' \
        'Usage: build-app.sh [--ui-test-harness] [--build-stamp VALUE]' \
        '' \
        '  --ui-test-harness  Build a local-only bundle that enables the unauthenticated' \
        '                     UI harness when KRIT_UI_TEST=1 is supplied at launch.' \
        '  --build-stamp      Override CFBundleVersion with one to three numeric components.'
}

UI_TEST_HARNESS=0
BUILD_STAMP_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ui-test-harness) UI_TEST_HARNESS=1 ;;
        --build-stamp)
            if [ "$#" -lt 2 ]; then
                echo "Error: --build-stamp requires a value" >&2
                usage >&2
                exit 2
            fi
            shift
            BUILD_STAMP_OVERRIDE="$1"
            ;;
        --build-stamp=*) BUILD_STAMP_OVERRIDE="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ -n "$BUILD_STAMP_OVERRIDE" ] && ! [[ "$BUILD_STAMP_OVERRIDE" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Error: --build-stamp must contain one to three numeric components" >&2
    exit 2
fi

if [ "$UI_TEST_HARNESS" -eq 1 ]; then
    BUILD_PATH="/tmp/krit-ui-test-build"
else
    BUILD_PATH="/tmp/krit-app-build"
fi

KEYBOARD_SHORTCUTS_PATCH="$SCRIPT_DIR/patches/keyboardshortcuts-2.4.0-resource-bundle.patch"
if [ ! -f "$KEYBOARD_SHORTCUTS_PATCH" ]; then
    echo "✗ KeyboardShortcuts resource patch not found: $KEYBOARD_SHORTCUTS_PATCH" >&2
    exit 1
fi
KEYBOARD_SHORTCUTS_PATCH_SHA="$(shasum -a 256 "$KEYBOARD_SHORTCUTS_PATCH" | awk '{print $1}')"

# Assemble and sign the bundle on an APFS path (BUILD_PATH), never inside the
# source tree. This keeps build artifacts out of the repo and, critically,
# avoids exFAT volumes whose ._* AppleDouble files break codesign. The signed
# bundle is copied to /Applications at the end.
APP_BUNDLE="$BUILD_PATH/$APP_NAME.app"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    # Local release credentials are intentionally optional.
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

SIGN_IDENTITY="${KRIT_CODESIGN_IDENTITY:--}"

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

# Keep dependency resolution locked to Package.resolved. SwiftPM's process
# sandbox stays enabled for normal builds; nested automation sandboxes can opt
# out explicitly when macOS refuses a second sandbox layer.
SWIFTPM_FLAGS=(--disable-index-store --force-resolved-versions)
SWIFTPM_RESOLVE_FLAGS=(--scratch-path "$BUILD_PATH" --force-resolved-versions)
if [ "${KRIT_DISABLE_SWIFTPM_SANDBOX:-0}" = "1" ]; then
    SWIFTPM_FLAGS+=(--disable-sandbox)
    SWIFTPM_RESOLVE_FLAGS+=(--disable-sandbox)
fi

# The distributed-notification UI harness is compiled only for an explicit local
# test bundle. A normal release build ignores KRIT_UI_TEST entirely, even when
# the caller has a similarly named environment variable set.
TEST_HARNESS_FLAGS=()
if [ "$UI_TEST_HARNESS" -eq 1 ]; then
    TEST_HARNESS_FLAGS=(-Xswiftc -D -Xswiftc KRIT_TEST_HARNESS)
    echo "▶ Including local UI test harness"
fi

# SwiftPM does not reliably invalidate object files when only a custom `-D`
# compilation condition changes. A stale object from a normal build makes a
# plist-marked harness silently ignore KRIT_UI_TEST, which is worse than a
# visible build failure. Keep one mode marker next to the disposable /tmp build
# tree and start clean only when that mode changes or an older tree has no marker.
BUILD_MODE="release:$KEYBOARD_SHORTCUTS_PATCH_SHA"
if [ "$UI_TEST_HARNESS" -eq 1 ]; then
    BUILD_MODE="ui-test-harness:$KEYBOARD_SHORTCUTS_PATCH_SHA"
fi
BUILD_MODE_FILE="$BUILD_PATH/.krit-build-mode"
if [ ! -f "$BUILD_MODE_FILE" ] || [ "$(cat "$BUILD_MODE_FILE")" != "$BUILD_MODE" ]; then
    echo "▶ Resetting stale $BUILD_MODE build artifacts…"
    rm -rf "$BUILD_PATH" "${BUILD_PATH}-cli"
    mkdir -p "$BUILD_PATH"
    printf '%s\n' "$BUILD_MODE" > "$BUILD_MODE_FILE"
fi

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
# SwiftPM incrementally copies resources into an existing bundle but does not
# remove files that disappeared from Sources. Recreate only KRIT's generated
# resource bundle so retired wallpapers cannot leak into a later release build.
if [ -d "$BUILD_PATH" ]; then
    find "$BUILD_PATH" -type d -name "Krit_KritKit.bundle" -prune -exec rm -rf {} +
fi

# SwiftPM's command-line resource accessor probes Bundle.main.bundleURL, which
# is the .app root on macOS. A signed macOS app must keep resources under
# Contents/Resources, so KeyboardShortcuts needs a deterministic source patch
# that resolves its localization bundle from the standard app layout instead.
echo "▶ Resolving locked dependencies…"
swift package "${SWIFTPM_RESOLVE_FLAGS[@]}" resolve
KEYBOARD_SHORTCUTS_CHECKOUT="$BUILD_PATH/checkouts/KeyboardShortcuts"
if [ ! -d "$KEYBOARD_SHORTCUTS_CHECKOUT" ]; then
    echo "✗ KeyboardShortcuts checkout not found under $BUILD_PATH/checkouts"
    exit 1
fi
if git -C "$KEYBOARD_SHORTCUTS_CHECKOUT" apply --reverse --check "$KEYBOARD_SHORTCUTS_PATCH" >/dev/null 2>&1; then
    echo "▶ KeyboardShortcuts resource patch already applied"
else
    if ! git -C "$KEYBOARD_SHORTCUTS_CHECKOUT" apply --check "$KEYBOARD_SHORTCUTS_PATCH"; then
        echo "✗ KeyboardShortcuts resource patch no longer applies cleanly"
        exit 1
    fi
    git -C "$KEYBOARD_SHORTCUTS_CHECKOUT" apply "$KEYBOARD_SHORTCUTS_PATCH"
    echo "▶ Applied KeyboardShortcuts resource patch"
fi
# Build ONLY the app target here. The "krit" CLI product collides with the "Krit"
# app binary in a shared release dir on case-insensitive volumes, so it is built
# separately below into its own path.
swift build -c release --product KritApp "${SWIFTPM_FLAGS[@]}" \
    "${ARCH_FLAGS[@]}" "${TEST_HARNESS_FLAGS[@]}" --build-path "$BUILD_PATH" 2>&1

# The CLI product is named "krit", which collides with the "Krit" app binary in
# the same release directory on case-insensitive volumes (APFS default, exFAT).
# Build it into a dedicated path so both binaries materialize.
CLI_BUILD_PATH="$BUILD_PATH-cli"
echo "▶ Building krit CLI (release, archs: $KRIT_ARCHS)…"
swift build -c release --product krit "${SWIFTPM_FLAGS[@]}" \
    "${ARCH_FLAGS[@]}" --build-path "$CLI_BUILD_PATH" 2>&1

# Locating the product binary has to survive THREE SPM output layouts:
#   - flat llbuild:        $BUILD_PATH/release/KritApp
#   - arch-triple llbuild: $BUILD_PATH/<triple>/release/KritApp   (explicit --build-path)
#   - multi-arch xcbuild:  $BUILD_PATH/apple/Products/Release/KritApp   (--arch a --arch b)
# The layout is DECIDED by how this run invoked swift build: with --arch flags
# the product lands in the xcbuild layout, without them in an llbuild layout.
# Probe the current run's layout FIRST — a shared build dir keeps artifacts from
# previous runs in the other layouts, and probing those first hands back a stale
# binary (e.g. an arm64-only KritApp from an earlier llbuild build, which then
# trips the arch assert with a misleading "missing arch" instead of being the
# wrong file). The find fallback covers the arch-triple layout; dSYM bundles
# carry a same-named binary, so exclude them.
locate_product() {
    local root="$1" name="$2"
    local primary
    if [ ${#ARCH_FLAGS[@]} -gt 0 ]; then
        primary="$root/apple/Products/Release/$name"
    else
        primary="$root/release/$name"
    fi
    if [ -f "$primary" ]; then
        echo "$primary"
        return
    fi
    find "$root" -name "$name" -type f -ipath "*/release/$name" ! -path "*.dSYM/*" 2>/dev/null | head -1
}

BINARY="$(locate_product "$BUILD_PATH" "KritApp")"
if [ ! -f "$BINARY" ]; then
    echo "✗ Build failed — binary not found under $BUILD_PATH"
    exit 1
fi
assert_archs "KritApp" "$BINARY"

# Locate the krit CLI binary from its dedicated build path (same layout rules).
CLI_BINARY="$(locate_product "$CLI_BUILD_PATH" "krit")"
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

if [ "$UI_TEST_HARNESS" -eq 1 ]; then
    if /usr/libexec/PlistBuddy -c "Print :KritUIHarnessBuild" "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :KritUIHarnessBuild true" "$APP_BUNDLE/Contents/Info.plist"
    else
        /usr/libexec/PlistBuddy -c "Add :KritUIHarnessBuild bool true" "$APP_BUNDLE/Contents/Info.plist"
    fi
else
    /usr/libexec/PlistBuddy -c "Delete :KritUIHarnessBuild" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

# Stamp the bundle with the build time so the installed app is identifiable:
#   defaults read /Applications/KRIT.app/Contents/Info CFBundleVersion
# answers "which build am I actually running?" without guessing.
# Local release verification can provide a deterministic stamp. Keeping that
# input on the command line avoids silently inheriting a build number from the
# environment, while normal builds continue to use the current build time.
BUILD_STAMP="${BUILD_STAMP_OVERRIDE:-$(date +%Y%m%d.%H%M)}"
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

# Copy EVERY SPM-generated resource bundle into the app, not just our own
# (Krit_KritKit, the capture sound). A package built with resources loads them
# through Bundle.module, which fatalErrors the instant its .bundle is missing
# from the app: that was the Shortcuts-tab crash (KeyboardShortcuts'
# RecorderCocoa -> String.localized -> Bundle.module on the absent
# KeyboardShortcuts_KeyboardShortcuts.bundle). Only copy bundles next to the
# binary produced by this build. Dependency trees contain test fixtures that
# must never leak into the application resources.
PRODUCTS_DIR="$(dirname "$BINARY")"
RESOURCE_BUNDLES=()
if [ -d "$PRODUCTS_DIR" ]; then
    for b in "$PRODUCTS_DIR"/*.bundle; do
        [ -d "$b" ] && RESOURCE_BUNDLES+=("$b")
    done
fi
if [ ${#RESOURCE_BUNDLES[@]} -eq 0 ]; then
    echo "✗ No resource bundles found next to $BINARY"
    exit 1
fi
for b in "${RESOURCE_BUNDLES[@]}"; do
    rm -rf "$APP_BUNDLE/Contents/Resources/$(basename "$b")"
    cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
    echo "▶ Bundled resource: $(basename "$b")"
done

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

echo "▶ Copying to $APP_DESTINATION…"
APPS_DEST="$APP_DESTINATION"
mkdir -p "$(dirname "$APPS_DEST")"
rm -rf "$APPS_DEST"
cp -R "$APP_BUNDLE" "$APPS_DEST"

echo ""
echo "✓ Done!  KRIT.app deployed to $APPS_DEST."
echo "  Launch it from $APPS_DEST."
if [ "$UI_TEST_HARNESS" -eq 1 ]; then
    echo "  This is a local UI harness bundle. Do not package or distribute it."
fi
echo ""
echo "  First launch: grant Screen Recording permission when prompted"
echo "  (System Settings → Privacy & Security → Screen Recording)"
