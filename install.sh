#!/usr/bin/env bash
# install.sh - Install KRIT from GitHub Releases.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.16.0/install.sh | bash
#   VERSION=0.16.0 bash install.sh
#
# The script downloads the published DMG from GitHub Releases, verifies its
# checksum and app signature, then installs KRIT.app in /Applications.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

has_color() {
    [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ "${FORCE_COLOR:-}" = "1" ]; }
}

if has_color; then
    BOLD='\033[1m'
    GREEN='\033[1;32m'
    CYAN='\033[1;36m'
    RED='\033[1;31m'
    YELLOW='\033[1;33m'
    RESET='\033[0m'
else
    BOLD='' GREEN='' CYAN='' RED='' YELLOW='' RESET=''
fi

info() { printf "%b▸%b %s\n" "${CYAN}" "${RESET}" "$*"; }
ok()   { printf "%b✔%b %s\n" "${GREEN}" "${RESET}" "$*"; }
warn() { printf "%b⚠%b %s\n" "${YELLOW}" "${RESET}" "$*" >&2; }
fail() { printf "%b✖%b %s\n" "${RED}" "${RESET}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || fail "KRIT is a macOS app. This script only works on macOS."

for cmd in codesign curl ditto hdiutil shasum xattr; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------

REPO="leonardocandiani/krit"

if [ -z "${VERSION:-}" ]; then
    info "Fetching latest release version…"
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep '"tag_name"' \
        | head -1 \
        | sed -E 's/.*"v?([^"]+)".*/\1/')"
    [ -n "$VERSION" ] || fail "Could not determine the latest release version."
fi

# Strip a leading "v" if present.
VERSION="${VERSION#v}"

# Reject anything that is not plain semver before using it in URLs and paths.
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "Invalid version: ${VERSION} (expected MAJOR.MINOR.PATCH, e.g. 0.16.0)"

DMG_NAME="KRIT-v${VERSION}-macOS.dmg"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${DMG_NAME}"

printf "\n%bKRIT Installer%b  •  v%s\n\n" "${BOLD}" "${RESET}" "$VERSION"

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

TMPDIR_INSTALL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

DMG_PATH="${TMPDIR_INSTALL}/${DMG_NAME}"

info "Downloading ${DMG_NAME}…"
if ! curl -fSL --progress-bar -o "$DMG_PATH" "$DOWNLOAD_URL"; then
    fail "Download failed. Check the version number and your network connection."
fi
ok "Downloaded ${DMG_NAME}"

# ---------------------------------------------------------------------------
# Verify integrity
# ---------------------------------------------------------------------------

# Each release ships a .sha256 next to the DMG. Verify the download against it
# before mounting anything, so a tampered DMG is rejected up front.
SHA_NAME="${DMG_NAME}.sha256"
SHA_PATH="${TMPDIR_INSTALL}/${SHA_NAME}"

info "Verifying checksum…"
if ! curl -fsSL -o "$SHA_PATH" "https://github.com/${REPO}/releases/download/v${VERSION}/${SHA_NAME}"; then
    fail "Could not download the checksum file (${SHA_NAME}). Refusing to install an unverified DMG."
fi
(cd "$TMPDIR_INSTALL" && shasum -a 256 -c "$SHA_NAME" >/dev/null 2>&1) \
    || fail "Checksum verification FAILED. The DMG does not match the published sha256. Aborting."
ok "Checksum verified"

# ---------------------------------------------------------------------------
# Mount, copy, unmount
# ---------------------------------------------------------------------------

MOUNT_POINT="${TMPDIR_INSTALL}/krit-dmg"
mkdir -p "$MOUNT_POINT"

info "Mounting disk image…"
hdiutil attach "$DMG_PATH" -nobrowse -quiet -mountpoint "$MOUNT_POINT" \
    || fail "Failed to mount the DMG."

# Unmount on exit regardless of where we bail out.
trap 'hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; rm -rf "$TMPDIR_INSTALL"' EXIT

INSTALL_DIR="/Applications"
SOURCE_APP="${MOUNT_POINT}/KRIT.app"
DESTINATION_APP="${INSTALL_DIR}/KRIT.app"

[ -d "$SOURCE_APP" ] || fail "Mounted DMG does not contain KRIT.app."

info "Verifying KRIT.app signature…"
codesign --verify --deep --strict "$SOURCE_APP" 2>/dev/null \
    || fail "Downloaded KRIT.app has an invalid code signature."

SIGNATURE_INFO="$(codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 || true)"
case "$SIGNATURE_INFO" in
    *"Signature=adhoc"*) SIGNATURE_MODE="adhoc" ;;
    *"Authority=Developer ID Application:"*) SIGNATURE_MODE="developer-id" ;;
    *) fail "Downloaded KRIT.app has an unsupported code signature." ;;
esac
ok "App signature verified"

info "Copying KRIT.app to ${INSTALL_DIR}…"

# Replace any existing installation.
if [ -d "$DESTINATION_APP" ]; then
    warn "Existing KRIT.app found, replacing."
    rm -rf "$DESTINATION_APP"
fi

ditto --rsrc --extattr "$SOURCE_APP" "$DESTINATION_APP" \
    || fail "Failed to copy KRIT.app. You may need to run with sudo."

codesign --verify --deep --strict "$DESTINATION_APP" 2>/dev/null \
    || fail "Installed KRIT.app failed signature verification."

if [ "$SIGNATURE_MODE" = "adhoc" ]; then
    info "Applying legacy ad-hoc launch compatibility…"
    xattr -rd com.apple.quarantine "$DESTINATION_APP" 2>/dev/null || true
    if xattr -r "$DESTINATION_APP" 2>/dev/null | grep -Fq "com.apple.quarantine"; then
        fail "Could not remove Gatekeeper quarantine from the legacy ad-hoc app."
    fi
    warn "Installed a legacy ad-hoc release. Gatekeeper quarantine was removed."
else
    ok "Developer ID signature detected; Gatekeeper quarantine preserved"
fi

info "Unmounting disk image…"
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true

ok "Installed KRIT.app to ${INSTALL_DIR}"

printf "\n%bInstallation complete!%b\n\n" "${GREEN}${BOLD}" "${RESET}"
printf "  Launch KRIT from your Applications folder or Spotlight.\n"
printf "  On first launch, grant %bScreen Recording%b permission when prompted\n" "${BOLD}" "${RESET}"
printf "  (System Settings -> Privacy & Security -> Screen Recording).\n\n"
