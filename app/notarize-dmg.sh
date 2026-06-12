#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

DMG_PATH="${1:-${KRIT_DMG_PATH:-}}"
NOTARY_PROFILE="${KRIT_NOTARY_PROFILE:-}"
# Direct Apple ID auth (used by CI) avoids any dependency on which keychain holds
# the stored profile. When all three are set, they take precedence over the profile.
NOTARY_APPLE_ID="${KRIT_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${KRIT_NOTARY_PASSWORD:-}"
NOTARY_TEAM_ID="${KRIT_NOTARY_TEAM_ID:-}"

usage() {
    cat <<'EOF'
Usage: bash notarize-dmg.sh /path/to/KRIT.dmg

Required local setup, not committed to git:
  1. Install your Developer ID Application certificate in Keychain.
  2. Store notary credentials in Keychain:
     xcrun notarytool store-credentials "KritNotaryProfile"
        (provide your Apple ID, app-specific password, and Team ID)
  3. Copy .env.example to .env.local and set:
     KRIT_NOTARY_PROFILE="KritNotaryProfile"

NOTE: Ad-hoc signing (KRIT_CODESIGN_IDENTITY="-") cannot be notarized.
Notarization requires a valid "Developer ID Application" certificate.

This script submits the DMG to Apple's notary service, waits for the
result, staples the ticket into the DMG, then validates the bundle.
It reads credentials from a Keychain profile (local dev). In CI, store
the profile non-interactively first:
  xcrun notarytool store-credentials "$KRIT_NOTARY_PROFILE" \
    --apple-id "$NOTARY_APPLE_ID" \
    --password "$NOTARY_PASSWORD" \
    --team-id "$NOTARY_TEAM_ID"
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ -z "$DMG_PATH" ]; then
    usage
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "✗ DMG not found: $DMG_PATH"
    exit 1
fi

# Pick auth mode: direct Apple ID (CI) if all three are present, else the keychain
# profile (local dev).
USE_DIRECT_AUTH=0
if [ -n "$NOTARY_APPLE_ID" ] && [ -n "$NOTARY_PASSWORD" ] && [ -n "$NOTARY_TEAM_ID" ]; then
    USE_DIRECT_AUTH=1
elif [ -z "$NOTARY_PROFILE" ]; then
    echo "✗ No notarization credentials set."
    echo "  Either set KRIT_NOTARY_APPLE_ID/KRIT_NOTARY_PASSWORD/KRIT_NOTARY_TEAM_ID,"
    echo "  or set KRIT_NOTARY_PROFILE to a stored Keychain profile."
    echo "  Run with --help for setup instructions."
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "✗ xcrun is required. Install Xcode command line tools first."
    exit 1
fi

echo "▶ Submitting $DMG_PATH for notarization…"
if [ "$USE_DIRECT_AUTH" -eq 1 ]; then
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$NOTARY_APPLE_ID" \
        --password "$NOTARY_PASSWORD" \
        --team-id "$NOTARY_TEAM_ID" \
        --wait
else
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "▶ Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"

echo "▶ Validating distribution…"
if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$DMG_PATH"
else
    spctl -a -t open -vvv --context context:primary-signature "$DMG_PATH"
fi

echo "✓ Notarized, stapled, and validated: $DMG_PATH"
