#!/usr/bin/env bash
#
# update-appcast.sh - Prepends a new <item> to appcast.xml for Sparkle updates.
#
# Usage:
#   scripts/release/update-appcast.sh <version> <build_number> <dmg_path> <ed_signature> [appcast_file] [download_url]
#
# Example:
#   scripts/release/update-appcast.sh 0.17.0 20260612.1530 app/KRIT-v0.17.0-macOS.dmg "base64sig=="
#
# release.sh calls this after signing the DMG with Sparkle's sign_update; the
# item it prepends is what shipped apps read (SUFeedURL points at the raw
# GitHub URL of appcast.xml on main).

set -euo pipefail

VERSION="${1:?Usage: update-appcast.sh <version> <build_number> <dmg_path> <ed_signature> [appcast_file] [download_url]}"
BUILD_NUMBER="${2:?missing build number}"
DMG_PATH="${3:?missing dmg path}"
ED_SIGNATURE="${4:?missing EdDSA signature}"
APPCAST_FILE="${5:-appcast.xml}"
DOWNLOAD_URL="${6:-https://github.com/leonardocandiani/krit/releases/download/v${VERSION}/KRIT-v${VERSION}-macOS.dmg}"

[ -f "$DMG_PATH" ]     || { echo "DMG file not found: $DMG_PATH" >&2; exit 1; }
[ -f "$APPCAST_FILE" ] || { echo "Appcast file not found: $APPCAST_FILE" >&2; exit 1; }

FILE_SIZE=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH")
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

ITEM_FILE="${APPCAST_FILE}.item.tmp"
cat > "$ITEM_FILE" << EOF
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <link>https://github.com/leonardocandiani/krit/releases/tag/v${VERSION}</link>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${FILE_SIZE}"
        type="application/octet-stream"/>
    </item>
EOF

# New items go right after <language>, so the newest release is the first item.
LANG_LINE=$(grep -n '<language>' "$APPCAST_FILE" | head -1 | cut -d: -f1)
if [ -z "$LANG_LINE" ]; then
  echo "Could not find <language> tag in $APPCAST_FILE" >&2
  rm -f "$ITEM_FILE"
  exit 1
fi

{
  head -n "$LANG_LINE" "$APPCAST_FILE"
  cat "$ITEM_FILE"
  tail -n +"$((LANG_LINE + 1))" "$APPCAST_FILE"
} > "${APPCAST_FILE}.tmp" && mv "${APPCAST_FILE}.tmp" "$APPCAST_FILE"

rm -f "$ITEM_FILE"

echo "Updated $APPCAST_FILE with v${VERSION} (build ${BUILD_NUMBER}, size ${FILE_SIZE} bytes)"
