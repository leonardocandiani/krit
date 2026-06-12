#!/usr/bin/env bash
# install.sh - Install KRIT from GitHub Releases.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/v0.16.0/install.sh | bash
#   VERSION=0.16.0 bash install.sh
#
# The script downloads the DMG from GitHub Releases, mounts it, copies KRIT.app
# to /Applications, unmounts, and strips the quarantine attribute so macOS does
# not block the (ad-hoc signed) app on first launch.

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

for cmd in curl hdiutil xattr; do
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

info "Copying KRIT.app to ${INSTALL_DIR}…"

# Replace any existing installation.
if [ -d "${INSTALL_DIR}/KRIT.app" ]; then
    warn "Existing KRIT.app found, replacing."
    rm -rf "${INSTALL_DIR}/KRIT.app"
fi

cp -R "${MOUNT_POINT}/KRIT.app" "${INSTALL_DIR}/" \
    || fail "Failed to copy KRIT.app. You may need to run with sudo."

info "Unmounting disk image…"
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true

ok "Installed KRIT.app to ${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# Post-install
# ---------------------------------------------------------------------------

# KRIT is ad-hoc signed, not notarized, so macOS quarantines the downloaded app.
# Strip the quarantine flag so it launches without a Gatekeeper block.
info "Removing quarantine attribute…"
xattr -rd com.apple.quarantine "${INSTALL_DIR}/KRIT.app" 2>/dev/null || true
ok "Quarantine attribute removed"

printf "\n%bInstallation complete!%b\n\n" "${GREEN}${BOLD}" "${RESET}"
printf "  Launch KRIT from your Applications folder or Spotlight.\n"
printf "  On first launch, grant %bScreen Recording%b permission when prompted\n" "${BOLD}" "${RESET}"
printf "  (System Settings -> Privacy & Security -> Screen Recording).\n\n"
