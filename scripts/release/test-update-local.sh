#!/usr/bin/env bash
#
# test-update-local.sh - E2E proof that the Sparkle in-app update works.
#
# Builds two throwaway versions of KRIT (99.0.0 installed, 99.0.1 inside a
# signed DMG), serves a local appcast over http://localhost:8089, triggers a
# background update check inside the running app, quits it, and asserts that
# Sparkle silently swapped /Applications/KRIT.app to 99.0.1.
#
# The pass criterion is the END of the flow (the installed bundle's version
# string), not any intermediate stage. Restores the real app afterwards.
#
# Usage:
#   scripts/release/test-update-local.sh
#
# Requirements: the Sparkle EdDSA private key in the login keychain (created
# once with generate_keys) and a swift toolchain.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/app"
INFO_PLIST="$APP_DIR/Info.plist"
TEST_DIR="/tmp/krit-update-test"
PORT=8089
V1="99.0.0"
V2="99.0.1"
# The appcast advertises a build number far above any real build stamp
# (YYYYMMDD.HHMM) so the offered update is always "newer" than the installed
# throwaway build, regardless of the order the two test builds were produced.
APPCAST_BUILD="99990101.0000"
DMG_NAME="KRIT-v$V2-macOS.dmg"
RESULT_JSON="/tmp/krit-update-check.json"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    defaults delete com.krit.app KritFeedURLOverride 2>/dev/null || true
    defaults delete com.krit.app SUAutomaticallyUpdate 2>/dev/null || true
    # Restore the real Info.plist if the backup still exists (failure mid-run).
    if [ -f "$TEST_DIR/Info.plist.bak" ]; then
        cp "$TEST_DIR/Info.plist.bak" "$INFO_PLIST"
    fi
}
trap cleanup EXIT

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cp "$INFO_PLIST" "$TEST_DIR/Info.plist.bak"

# ---------------------------------------------------------------------------
# Build v2 (the update) and package its DMG
# ---------------------------------------------------------------------------

info "Building v$V2 (update payload)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V2" "$INFO_PLIST"
bash "$APP_DIR/build-app.sh" >/dev/null
bash "$APP_DIR/make-dmg.sh" >/dev/null
[ -f "$APP_DIR/$DMG_NAME" ] || fail "DMG not produced: $APP_DIR/$DMG_NAME"
mv "$APP_DIR/$DMG_NAME" "$TEST_DIR/"
rm -f "$APP_DIR/$DMG_NAME.sha256"
ok "v$V2 packaged: $TEST_DIR/$DMG_NAME"

# ---------------------------------------------------------------------------
# Build v1 (the "old" app the user is running)
# ---------------------------------------------------------------------------

info "Building v$V1 (installed baseline)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V1" "$INFO_PLIST"
bash "$APP_DIR/build-app.sh" >/dev/null
cp "$TEST_DIR/Info.plist.bak" "$INFO_PLIST"
INSTALLED="$(defaults read /Applications/KRIT.app/Contents/Info CFBundleShortVersionString)"
[ "$INSTALLED" = "$V1" ] || fail "Expected v$V1 installed, found $INSTALLED"
ok "v$V1 deployed to /Applications"

# ---------------------------------------------------------------------------
# Sign the DMG and write the local appcast
# ---------------------------------------------------------------------------

SIGN_UPDATE="$(find "$APP_DIR/.build/artifacts" /tmp/krit-app-build/artifacts -maxdepth 5 -name "sign_update" -type f -not -path "*old_dsa*" 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || fail "Sparkle sign_update not found (run swift build in app/ first)"
chmod +x "$SIGN_UPDATE" 2>/dev/null || true

info "Signing DMG (EdDSA, key from keychain)"
ED_SIG="$("$SIGN_UPDATE" -p "$TEST_DIR/$DMG_NAME")"
[ -n "$ED_SIG" ] || fail "sign_update produced no signature"
FILE_SIZE="$(stat -f%z "$TEST_DIR/$DMG_NAME")"
PUB_DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$TEST_DIR/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>KRIT (local test)</title>
    <language>en</language>
    <item>
      <title>Version $V2</title>
      <sparkle:version>$APPCAST_BUILD</sparkle:version>
      <sparkle:shortVersionString>$V2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url="http://localhost:$PORT/$DMG_NAME"
        sparkle:edSignature="$ED_SIG"
        length="$FILE_SIZE"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
ok "Local appcast written"

# ---------------------------------------------------------------------------
# Serve the feed and point the app at it
# ---------------------------------------------------------------------------

info "Serving $TEST_DIR on http://localhost:$PORT"
(cd "$TEST_DIR" && python3 -m http.server "$PORT" >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1
curl -fsS "http://localhost:$PORT/appcast.xml" >/dev/null || fail "Local server did not come up"

defaults write com.krit.app KritFeedURLOverride "http://localhost:$PORT/appcast.xml"
defaults write com.krit.app SUAutomaticallyUpdate -bool YES

# ---------------------------------------------------------------------------
# Launch v1 and trigger the background check
# ---------------------------------------------------------------------------

info "Launching v$V1 and triggering the update check"
pkill -x KRIT 2>/dev/null || true
sleep 1
open -n --env KRIT_UI_TEST=1 /Applications/KRIT.app
sleep 4

rm -f "$RESULT_JSON"
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"com.krit.test.ui\"), object: \"update-check|$RESULT_JSON\", userInfo: nil, deliverImmediately: true)" 2>/dev/null
for _ in $(seq 1 30); do
    [ -s "$RESULT_JSON" ] && break
    sleep 1
done
if [ -s "$RESULT_JSON" ]; then
    info "update-check probe: $(cat "$RESULT_JSON")"
else
    info "update-check probe: no result (scheduled check may have raced it; the final assert below is what counts)"
fi

# Give Sparkle time to download + extract + arm the install-on-quit.
info "Waiting for the silent download to complete"
sleep 25

# ---------------------------------------------------------------------------
# Quit and assert the swap
# ---------------------------------------------------------------------------

info "Quitting the app (Sparkle installs on exit)"
pkill -x KRIT 2>/dev/null || true

SWAPPED=""
for _ in $(seq 1 30); do
    sleep 2
    CUR="$(defaults read /Applications/KRIT.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true)"
    if [ "$CUR" = "$V2" ]; then SWAPPED=1; break; fi
done

# ---------------------------------------------------------------------------
# Restore the real app before reporting
# ---------------------------------------------------------------------------

info "Restoring the real build in /Applications"
pkill -x KRIT 2>/dev/null || true
bash "$APP_DIR/build-app.sh" >/dev/null
ok "Restored $(defaults read /Applications/KRIT.app/Contents/Info CFBundleShortVersionString)"

if [ -n "$SWAPPED" ]; then
    ok "PASS: Sparkle updated /Applications/KRIT.app from v$V1 to v$V2"
else
    fail "FAIL: bundle still at ${CUR:-unknown} after quit (expected $V2)"
fi
