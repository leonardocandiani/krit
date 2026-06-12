#!/usr/bin/env bash
#
# release.sh - Official KRIT release pipeline.
#
# Cuts a GitHub release for KRIT: bumps the app version, builds and signs the
# app bundle, packages a DMG, tags the commit, and publishes the release with
# the DMG attached. Modeled on the Snapzy release flow (DMG + install.sh + brew
# tap served from this repo).
#
# Usage:
#   scripts/release/release.sh <version> [notes-file]
#   scripts/release/release.sh 0.16.0
#   scripts/release/release.sh 0.16.0 path/to/notes.md
#   echo "release notes here" | scripts/release/release.sh 0.16.0
#
# What it does, in order:
#   1. Verifies the working tree is clean and gh is authenticated.
#   2. Reads the target version from the first argument (e.g. 0.16.0).
#   3. Bumps CFBundleShortVersionString in app/Info.plist to that version.
#   4. Builds the app bundle    (app/build-app.sh) and deploys it to /Applications.
#   5. Packages the DMG         (app/make-dmg.sh)  -> app/KRIT-v<version>-macOS.dmg.
#   6. Creates an annotated git tag v<version>.
#   7. Publishes the release    (gh release create) with the DMG attached and
#      notes from the notes-file argument, stdin, or an auto-generated stub.
#
# The DMG artifact name is KRIT-v<version>-macOS.dmg. That suffix is fixed by
# app/make-dmg.sh and is also what Casks/krit.rb expects. Do not rename it here
# without updating both, or the cask URL breaks.
#
# This script is idempotent up to the point of side effects: re-running it for a
# version whose tag or release already exists fails fast with a clear message
# instead of producing a half-published release.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/app"
INFO_PLIST="$APP_DIR/Info.plist"
BUILD_SCRIPT="$APP_DIR/build-app.sh"
DMG_SCRIPT="$APP_DIR/make-dmg.sh"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

VERSION="${1:-}"
NOTES_FILE="${2:-}"

if [ -z "$VERSION" ]; then
    fail "Usage: scripts/release/release.sh <version> [notes-file]  (e.g. 0.16.0)"
fi

# Accept either "0.16.0" or "v0.16.0"; normalize to the bare semver.
VERSION="${VERSION#v}"

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "Version must be semver MAJOR.MINOR.PATCH (e.g. 0.16.0), got: $VERSION"
fi

TAG="v$VERSION"
DMG_NAME="KRIT-v$VERSION-macOS.dmg"
DMG_PATH="$APP_DIR/$DMG_NAME"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

info "Running pre-flight checks for $TAG"

[ "$(uname -s)" = "Darwin" ] || fail "Releases must be built on macOS (codesign, hdiutil)."

for cmd in git gh defaults swift hdiutil; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

[ -f "$BUILD_SCRIPT" ] || fail "Build script not found: $BUILD_SCRIPT"
[ -f "$DMG_SCRIPT" ]   || fail "DMG script not found: $DMG_SCRIPT"
[ -f "$INFO_PLIST" ]   || fail "Info.plist not found: $INFO_PLIST"

# gh must be authenticated, or `gh release create` fails late after a full build.
if ! gh auth status >/dev/null 2>&1; then
    fail "gh is not authenticated. Run: gh auth login"
fi

# Working tree must be clean so the tag points at a known, reviewable commit.
cd "$REPO_ROOT"
if [ -n "$(git status --porcelain)" ]; then
    fail "Working tree is not clean. Commit or stash changes before releasing."
fi

# Refuse to clobber an existing tag or release for this version.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists. Bump the version or delete the tag first."
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    fail "Release $TAG already exists on GitHub. Choose a new version."
fi

ok "Pre-flight checks passed."

# ---------------------------------------------------------------------------
# Resolve release notes (file > stdin > generated stub)
# ---------------------------------------------------------------------------

NOTES_TMP="$(mktemp -t krit-release-notes)"
cleanup() { rm -f "$NOTES_TMP"; }
trap cleanup EXIT

if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || fail "Notes file not found: $NOTES_FILE"
    cat "$NOTES_FILE" > "$NOTES_TMP"
    info "Release notes: $NOTES_FILE"
elif [ ! -t 0 ]; then
    # Notes piped in on stdin.
    cat > "$NOTES_TMP"
    info "Release notes: read from stdin"
fi

if [ ! -s "$NOTES_TMP" ]; then
    info "No notes provided. Generating a stub from git log since the last tag"
    PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    {
        printf '## KRIT %s\n\n' "$TAG"
        if [ -n "$PREV_TAG" ]; then
            printf 'Changes since %s:\n\n' "$PREV_TAG"
            git log --pretty='- %s' "$PREV_TAG"..HEAD
        else
            printf 'Initial release.\n'
        fi
        printf '\n### Install\n\n'
        printf '```bash\n'
        printf 'brew tap leonardocandiani/krit https://github.com/leonardocandiani/krit\n'
        printf 'brew install --cask krit\n'
        printf '```\n\n'
        printf 'Or:\n\n'
        printf '```bash\n'
        printf 'curl -fsSL https://raw.githubusercontent.com/leonardocandiani/krit/%s/install.sh | bash\n' "$TAG"
        printf '```\n\n'
        printf 'On first launch, grant Screen Recording permission in System Settings.\n'
    } > "$NOTES_TMP"
fi

# ---------------------------------------------------------------------------
# Bump the app version
# ---------------------------------------------------------------------------

CURRENT_VERSION="$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || true)"
info "Bumping CFBundleShortVersionString: ${CURRENT_VERSION:-unknown} -> $VERSION"

# PlistBuddy edits the plist in place. build-app.sh copies this Info.plist into
# the bundle verbatim, so the bump propagates to the built app.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"

NEW_VERSION="$(defaults read "$INFO_PLIST" CFBundleShortVersionString)"
[ "$NEW_VERSION" = "$VERSION" ] || fail "Version bump did not take effect (read back: $NEW_VERSION)."
ok "Version set to $VERSION in app/Info.plist"

# ---------------------------------------------------------------------------
# Build the app
# ---------------------------------------------------------------------------

info "Building KRIT.app (release)"
bash "$BUILD_SCRIPT"
ok "App built and deployed to /Applications/KRIT.app"

# ---------------------------------------------------------------------------
# Package the DMG
# ---------------------------------------------------------------------------

# make-dmg.sh reads the version from the installed app and writes the DMG next
# to itself (app/). Clear any stale DMG for this version first so we package a
# fresh one.
rm -f "$DMG_PATH"

info "Packaging $DMG_NAME"
bash "$DMG_SCRIPT"

[ -f "$DMG_PATH" ] || fail "Expected DMG not produced: $DMG_PATH"
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
ok "DMG packaged: $DMG_PATH"
info "DMG sha256: $DMG_SHA"

# Publish a checksum file next to the DMG so install.sh can verify the
# download before mounting it (supply-chain integrity for curl | bash).
SHA_FILE="$DMG_PATH.sha256"
printf '%s  %s\n' "$DMG_SHA" "$DMG_NAME" > "$SHA_FILE"

# ---------------------------------------------------------------------------
# Sparkle: sign the DMG and prepend the appcast item
# ---------------------------------------------------------------------------

# sign_update ships inside the Sparkle SPM artifact; the EdDSA private key
# lives in the login keychain (created once with generate_keys). Shipped apps
# verify the signature against SUPublicEDKey in Info.plist, so a release
# without a valid signature would be ignored by the updater.
SIGN_UPDATE="$(find "$APP_DIR/.build/artifacts" /tmp/krit-app-build/artifacts -maxdepth 5 -name "sign_update" -type f -not -path "*old_dsa*" 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || fail "Sparkle sign_update not found. Run a swift build in app/ first."
chmod +x "$SIGN_UPDATE" 2>/dev/null || true

info "Signing DMG for Sparkle (EdDSA)"
ED_SIG="$("$SIGN_UPDATE" -p "$DMG_PATH")"
[ -n "$ED_SIG" ] || fail "sign_update produced no signature. Is the Sparkle key in the keychain?"
ok "EdDSA signature: $ED_SIG"

# sparkle:version compares against the installed app's CFBundleVersion, which
# build-app.sh stamps with the build time (YYYYMMDD.HHMM) — monotonic across
# releases by construction.
BUILD_NUMBER="$(defaults read /Applications/KRIT.app/Contents/Info CFBundleVersion)"

info "Updating appcast.xml"
bash "$SCRIPT_DIR/update-appcast.sh" "$VERSION" "$BUILD_NUMBER" "$DMG_PATH" "$ED_SIG" "$REPO_ROOT/appcast.xml"

# ---------------------------------------------------------------------------
# Bump the Homebrew cask
# ---------------------------------------------------------------------------

CASK_FILE="$REPO_ROOT/Casks/krit.rb"
if [ -f "$CASK_FILE" ]; then
    info "Bumping Casks/krit.rb to $VERSION"
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
              -e "s/^  sha256 \".*\"/  sha256 \"$DMG_SHA\"/" "$CASK_FILE"
fi

# ---------------------------------------------------------------------------
# Commit, tag and publish
# ---------------------------------------------------------------------------

# The tag must point at a commit that already carries the version bump, the
# appcast entry and the cask digest; shipped apps read appcast.xml from main,
# so main gets pushed before the release is published.
info "Committing release metadata"
git add "$INFO_PLIST" "$REPO_ROOT/appcast.xml" "$CASK_FILE"
git commit -m "chore: release $TAG

- bump CFBundleShortVersionString to $VERSION
- appcast entry for the Sparkle in-app update
- cask digest $DMG_SHA

Autor: Leonardo Candiani"

info "Creating git tag $TAG"
git tag -a "$TAG" -m "KRIT $TAG"

info "Publishing GitHub release $TAG with $DMG_NAME"
git push origin HEAD
git push origin "$TAG"
gh release create "$TAG" "$DMG_PATH" "$SHA_FILE" \
    --title "KRIT $TAG" \
    --notes-file "$NOTES_TMP"

ok "Released $TAG"
printf '\n'
printf '  Release:  https://github.com/leonardocandiani/krit/releases/tag/%s\n' "$TAG"
printf '  DMG:      %s\n' "$DMG_NAME"
printf '  sha256:   %s\n' "$DMG_SHA"
printf '  appcast:  entry for %s pushed to main (in-app updates live)\n' "$TAG"
