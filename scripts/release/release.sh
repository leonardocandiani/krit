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
#   1. Verifies the working tree, GitHub access, and selected distribution mode
#      before mutating release metadata.
#   2. Reads the target version from the first argument (e.g. 0.16.0).
#   3. Bumps CFBundleShortVersionString in app/Info.plist to that version.
#   4. Runs tests, builds and verifies the signed app bundle.
#   5. Packages the DMG -> app/KRIT-v<version>-macOS.dmg and notarizes it in
#      the default distribution mode.
#   6. Creates an annotated git tag v<version>.
#   7. Publishes the release (gh release create) with the DMG attached and
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
NOTARIZE_SCRIPT="$APP_DIR/notarize-dmg.sh"
WHATSNEW_FILE="$APP_DIR/Sources/Krit/Resources/WhatsNew.md"
CHANGELOG_FILE="$REPO_ROOT/CHANGELOG.md"
CASK_FILE="$REPO_ROOT/Casks/krit.rb"
APPCAST_FILE="$REPO_ROOT/appcast.xml"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
BUNDLE_LAYOUT_TEST="$SCRIPT_DIR/test-app-bundle-layout.sh"

# Distribution mode is a per-invocation decision. Capture it before loading
# credentials so a forgotten .env.local value cannot downgrade future releases.
REQUESTED_RELEASE_MODE="${KRIT_RELEASE_MODE:-notarized}"

# Load local credentials early so their absence fails before the version bump
# changes any tracked source file.
if [ -f "$APP_DIR/.env.local" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$APP_DIR/.env.local"
    set +a
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

RELEASE_MODE="$REQUESTED_RELEASE_MODE"
case "$RELEASE_MODE" in
    notarized)
        RELEASE_CODESIGN_IDENTITY="${KRIT_CODESIGN_IDENTITY:-}"
        RELEASE_DMG_SIGN_IDENTITY="$RELEASE_CODESIGN_IDENTITY"
        ;;
    adhoc)
        # Compatibility mode mirrors the historical public artifacts. It must
        # be selected explicitly and never becomes the release default.
        RELEASE_CODESIGN_IDENTITY="-"
        RELEASE_DMG_SIGN_IDENTITY=""
        ;;
    *)
        fail "KRIT_RELEASE_MODE must be 'notarized' or 'adhoc', got: $RELEASE_MODE"
        ;;
esac

assert_universal_binary() {
    local label="$1" path="$2" archs required
    archs="$(lipo -archs "$path" 2>/dev/null)" || \
        fail "$label is not a readable Mach-O binary: $path"
    for required in arm64 x86_64; do
        case " $archs " in
            *" $required "*) ;;
            *) fail "$label is missing $required (has: ${archs:-none}): $path" ;;
        esac
    done
    ok "$label is universal: $archs"
}

# A Git index lock represents an active or interrupted write. A release must
# never guess that it is stale: deleting a valid lock risks corrupting another
# Git operation running in the same worktree.
assert_no_index_lock() {
    local lock="$REPO_ROOT/.git/index.lock"
    [ -e "$lock" ] || return 0
    fail "Git index lock exists at $lock. Refusing to remove it automatically; resolve the active or stale operation before releasing."
}

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
# Keep release assembly isolated from the running development install. A failed
# release must not overwrite /Applications/KRIT.app before its DMG is published.
RELEASE_APP_PATH="/tmp/krit-release-$VERSION/KRIT.app"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

info "Running pre-flight checks for $TAG"

[ "$(uname -s)" = "Darwin" ] || fail "Releases must be built on macOS (codesign, hdiutil)."

for cmd in git gh defaults swift hdiutil codesign security xcrun lipo; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

[ -f "$BUILD_SCRIPT" ] || fail "Build script not found: $BUILD_SCRIPT"
[ -f "$DMG_SCRIPT" ]   || fail "DMG script not found: $DMG_SCRIPT"
[ -f "$NOTARIZE_SCRIPT" ] || fail "Notarization script not found: $NOTARIZE_SCRIPT"
[ -f "$INFO_PLIST" ]   || fail "Info.plist not found: $INFO_PLIST"
[ -f "$INSTALL_SCRIPT" ] || fail "Installer script not found: $INSTALL_SCRIPT"
[ -f "$BUNDLE_LAYOUT_TEST" ] || fail "Bundle layout test not found: $BUNDLE_LAYOUT_TEST"

# gh must be authenticated, or `gh release create` fails late after a full build.
if ! gh auth status >/dev/null 2>&1; then
    fail "gh is not authenticated. Run: gh auth login"
fi

# Everything below fails in seconds instead of after the full build. Each check
# maps to a real release that died mid-flight: a clone without origin, a wrong
# committer identity, a keychain without the Sparkle key, a stale local main.
ORIGIN_URL="$(cd "$REPO_ROOT" && git remote get-url origin 2>/dev/null || true)"
if [ -z "$ORIGIN_URL" ]; then
    fail "No 'origin' remote. Run: git remote add origin https://github.com/leonardocandiani/krit.git"
fi
case "$ORIGIN_URL" in
    *leonardocandiani/krit*) ;;
    *) fail "origin points to $ORIGIN_URL; releases are cut from leonardocandiani/krit." ;;
esac

CURRENT_BRANCH="$(cd "$REPO_ROOT" && git branch --show-current)"
if [ "$CURRENT_BRANCH" != "main" ]; then
    fail "Releases must be cut from main, not '${CURRENT_BRANCH:-detached HEAD}'."
fi

MAINTAINER_EMAIL="llima.leo.lima@gmail.com"
GIT_EMAIL="$(cd "$REPO_ROOT" && git config user.email || true)"
if [ "$GIT_EMAIL" != "$MAINTAINER_EMAIL" ]; then
    fail "git user.email is '${GIT_EMAIL:-unset}'; the release commit must be authored as $MAINTAINER_EMAIL. Run: git config user.email $MAINTAINER_EMAIL"
fi

if [ "$RELEASE_MODE" = "notarized" ]; then
    case "$RELEASE_CODESIGN_IDENTITY" in
        "Developer ID Application:"*) ;;
        *) fail "KRIT_CODESIGN_IDENTITY must name a Developer ID Application certificate. Use KRIT_RELEASE_MODE=adhoc only for an explicitly approved legacy release." ;;
    esac

    if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$RELEASE_CODESIGN_IDENTITY"; then
        fail "Developer ID identity not available in this keychain: $RELEASE_CODESIGN_IDENTITY"
    fi

    if [ -n "${KRIT_NOTARY_APPLE_ID:-}" ] || [ -n "${KRIT_NOTARY_PASSWORD:-}" ] || [ -n "${KRIT_NOTARY_TEAM_ID:-}" ]; then
        if [ -z "${KRIT_NOTARY_APPLE_ID:-}" ] || [ -z "${KRIT_NOTARY_PASSWORD:-}" ] || [ -z "${KRIT_NOTARY_TEAM_ID:-}" ]; then
            fail "Set all of KRIT_NOTARY_APPLE_ID, KRIT_NOTARY_PASSWORD, and KRIT_NOTARY_TEAM_ID, or use KRIT_NOTARY_PROFILE."
        fi
    elif [ -z "${KRIT_NOTARY_PROFILE:-}" ]; then
        fail "Set KRIT_NOTARY_PROFILE or the full direct notarization credential set before releasing."
    elif ! security find-generic-password -l "$KRIT_NOTARY_PROFILE" >/dev/null 2>&1; then
        fail "Notarization profile not found in this keychain: $KRIT_NOTARY_PROFILE"
    fi

else
    info "Legacy ad-hoc release mode explicitly enabled for $TAG"
fi

for installer in "$INSTALL_SCRIPT" "$CASK_FILE"; do
    grep -Fq "Signature=adhoc" "$installer" || \
        fail "Ad-hoc installer compatibility policy missing from $installer"
    grep -Fq "Authority=Developer ID Application:" "$installer" || \
        fail "Developer ID installer policy missing from $installer"
done

# The EdDSA private key must be in the login keychain BEFORE we spend minutes
# building; without it the DMG cannot be signed and the updater ignores the release.
if ! security find-generic-password -l "Private key for signing Sparkle updates" >/dev/null 2>&1; then
    fail "Sparkle EdDSA key not found in the login keychain (generate_keys creates it). Releases must be cut on the maintainer's machine."
fi

# Tagging a stale main would ship a release without the latest merged PRs.
(cd "$REPO_ROOT" && git fetch origin main --quiet)
BEHIND="$(cd "$REPO_ROOT" && git rev-list --count HEAD..origin/main)"
if [ "$BEHIND" != "0" ]; then
    fail "Local branch is $BEHIND commit(s) behind origin/main. Sync first (git pull origin main)."
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
METADATA_BACKUP_DIR="$(mktemp -d -t krit-release-metadata)"
RELEASE_METADATA_MUTATED=false
RELEASE_COMMITTED=false
METADATA_FILES=(
    "$INFO_PLIST"
    "$WHATSNEW_FILE"
    "$CHANGELOG_FILE"
    "$APPCAST_FILE"
    "$CASK_FILE"
)

backup_release_metadata() {
    local path name
    for path in "${METADATA_FILES[@]}"; do
        name="$(basename "$path")"
        if [ -e "$path" ]; then
            cp -p "$path" "$METADATA_BACKUP_DIR/$name"
        else
            : > "$METADATA_BACKUP_DIR/$name.absent"
        fi
    done
}

restore_release_metadata() {
    local path name
    for path in "${METADATA_FILES[@]}"; do
        name="$(basename "$path")"
        if [ -f "$METADATA_BACKUP_DIR/$name" ]; then
            cp -p "$METADATA_BACKUP_DIR/$name" "$path"
        elif [ -f "$METADATA_BACKUP_DIR/$name.absent" ]; then
            rm -f "$path"
        fi
    done
    git reset --quiet HEAD -- "${METADATA_FILES[@]}" || true
}

cleanup() {
    local status=$?
    trap - EXIT INT HUP TERM
    if [ "$status" -ne 0 ] && [ "$RELEASE_METADATA_MUTATED" = true ] && [ "$RELEASE_COMMITTED" != true ]; then
        info "Release failed before commit; restoring release metadata."
        restore_release_metadata || true
    fi
    rm -f "$NOTES_TMP" || true
    rm -rf "$METADATA_BACKUP_DIR" || true
    return "$status"
}

handle_signal() {
    exit "$1"
}

trap 'handle_signal 130' INT
trap 'handle_signal 129' HUP
trap 'handle_signal 143' TERM
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

backup_release_metadata
RELEASE_METADATA_MUTATED=true

CURRENT_VERSION="$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || true)"
info "Bumping CFBundleShortVersionString: ${CURRENT_VERSION:-unknown} -> $VERSION"

# PlistBuddy edits the plist in place. build-app.sh copies this Info.plist into
# the bundle verbatim, so the bump propagates to the built app.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"

NEW_VERSION="$(defaults read "$INFO_PLIST" CFBundleShortVersionString)"
[ "$NEW_VERSION" = "$VERSION" ] || fail "Version bump did not take effect (read back: $NEW_VERSION)."
ok "Version set to $VERSION in app/Info.plist"

# Bundle the release notes so the in-app "What's New" panel shows them after the
# update. Written BEFORE the build so it ships inside the app; the leading
# "version:" line gates the panel to this exact build.
{ printf 'version: %s\n' "$VERSION"; cat "$NOTES_TMP"; } > "$WHATSNEW_FILE"
ok "What's New notes bundled for $VERSION"

# Prepend the same notes to CHANGELOG.md (Keep-a-Changelog style: newest first,
# right under the "# Changelog" heading). Section headers in the notes are demoted
# to ### so they nest under the ## version. Skipped if the entry already exists.
if [ -f "$CHANGELOG_FILE" ] && ! grep -q "^## $VERSION$" "$CHANGELOG_FILE"; then
    CL_TMP="$(mktemp -t krit-changelog)"
    {
        printf '# Changelog\n\nAll notable changes to KRIT, newest first.\n\n'
        if grep -q '^## Unreleased$' "$CHANGELOG_FILE"; then
            # Keep the empty Unreleased slot first, then move its existing
            # details under the version being published.
            printf '## Unreleased\n\n'
            printf '## %s\n\n' "$VERSION"
            sed 's/^## /### /' "$NOTES_TMP"
            printf '\n'
            tail -n +5 "$CHANGELOG_FILE" | sed '1{/^## Unreleased$/d;}'
        else
            printf '## %s\n\n' "$VERSION"
            sed 's/^## /### /' "$NOTES_TMP"
            printf '\n'
            # Everything after the existing header block (skip the first 4 lines:
            # title, blank, intro, blank).
            tail -n +5 "$CHANGELOG_FILE"
        fi
    } > "$CL_TMP"
    mv "$CL_TMP" "$CHANGELOG_FILE"
    ok "CHANGELOG.md updated for $VERSION"
fi

# ---------------------------------------------------------------------------
# Build the app
# ---------------------------------------------------------------------------

info "Running test suite"
(cd "$APP_DIR" && swift test --disable-index-store --force-resolved-versions)
ok "Test suite passed."

info "Building KRIT.app (release)"
RELEASE_BUILD_STAMP="$(date +%Y%m%d.%H%M.%S)"
KRIT_ARCHS="arm64 x86_64" \
KRIT_APP_DESTINATION="$RELEASE_APP_PATH" \
KRIT_CODESIGN_IDENTITY_OVERRIDE="$RELEASE_CODESIGN_IDENTITY" \
    bash "$BUILD_SCRIPT" --build-stamp "$RELEASE_BUILD_STAMP"
ok "App built at $RELEASE_APP_PATH"

assert_universal_binary "KRIT app" "$RELEASE_APP_PATH/Contents/MacOS/KRIT"
assert_universal_binary "krit CLI" "$RELEASE_APP_PATH/Contents/Helpers/krit"

info "Verifying the signed app bundle"
codesign --verify --deep --strict --verbose=4 "$RELEASE_APP_PATH"
ok "App signature verified."

info "Verifying resource bundle independence"
KRIT_BUILD_PATHS_TO_HIDE=/tmp/krit-app-build \
    bash "$BUNDLE_LAYOUT_TEST" "$RELEASE_APP_PATH"
ok "Resource bundle independence verified."

# ---------------------------------------------------------------------------
# Package the DMG
# ---------------------------------------------------------------------------

# make-dmg.sh reads the version from the isolated release bundle and writes the
# DMG next to itself (app/). Clear any stale DMG for this version first so we
# package a fresh one.
rm -f "$DMG_PATH"

info "Packaging $DMG_NAME"
KRIT_APP_PATH="$RELEASE_APP_PATH" \
KRIT_DMG_SIGN_IDENTITY="$RELEASE_DMG_SIGN_IDENTITY" \
    bash "$DMG_SCRIPT"

[ -f "$DMG_PATH" ] || fail "Expected DMG not produced: $DMG_PATH"

if [ "$RELEASE_MODE" = "notarized" ]; then
    info "Notarizing and stapling $DMG_NAME"
    bash "$NOTARIZE_SCRIPT" "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    ok "DMG notarization verified."
else
    RELEASE_SIGNATURE_INFO="$(codesign -dv --verbose=4 "$RELEASE_APP_PATH" 2>&1)" || \
        fail "Could not inspect the legacy release bundle signature."
    case "$RELEASE_SIGNATURE_INFO" in
        *"Signature=adhoc"*) ;;
        *) fail "Legacy release bundle is not ad-hoc signed." ;;
    esac
    if codesign -d "$DMG_PATH" >/dev/null 2>&1; then
        fail "Legacy release DMG was signed unexpectedly."
    fi
    ok "Legacy ad-hoc bundle verified; notarization intentionally skipped."
fi

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
# Search every place SPM may have put the Sparkle artifact bundle: the explicit
# build path used by build-app.sh, a legacy in-repo .build, and the user-level
# SPM artifact cache. No -maxdepth: the artifactbundle layout nests deeper than
# 5 levels in newer SPM/Sparkle versions, which made the old bounded find miss
# it and abort the release after the DMG was already packaged.
# Only search directories that exist: under set -e + pipefail, find exits
# non-zero when ANY listed path is missing, which killed the whole release
# with no message even though the binary had been found in another path.
SIGN_SEARCH_DIRS=""
for d in /tmp/krit-app-build/artifacts "$APP_DIR/.build/artifacts" "$HOME/Library/Caches/org.swift.swiftpm/artifacts"; do
    [ -d "$d" ] && SIGN_SEARCH_DIRS="$SIGN_SEARCH_DIRS $d"
done
[ -n "$SIGN_SEARCH_DIRS" ] || fail "No Sparkle artifact directory exists. Run a swift build in app/ first."
# shellcheck disable=SC2086  # word splitting of the dir list is intended
SIGN_UPDATE="$(find $SIGN_SEARCH_DIRS -name "sign_update" -type f -not -path "*old_dsa*" 2>/dev/null | head -1 || true)"
[ -n "$SIGN_UPDATE" ] || fail "Sparkle sign_update not found under:$SIGN_SEARCH_DIRS. Run a swift build in app/ first."
info "Using sign_update: $SIGN_UPDATE"
chmod +x "$SIGN_UPDATE" 2>/dev/null || true

info "Signing DMG for Sparkle (EdDSA)"
ED_SIG="$("$SIGN_UPDATE" -p "$DMG_PATH")"
[ -n "$ED_SIG" ] || fail "sign_update produced no signature. Is the Sparkle key in the keychain?"
ok "EdDSA signature: $ED_SIG"

# sparkle:version compares against the installed app's CFBundleVersion, which
# release.sh supplies one build stamp with second precision
# (YYYYMMDD.HHMM.SS), keeping the appcast and the signed bundle in lockstep.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RELEASE_APP_PATH/Contents/Info.plist")"

info "Updating appcast.xml"
bash "$SCRIPT_DIR/update-appcast.sh" "$VERSION" "$BUILD_NUMBER" "$DMG_PATH" "$ED_SIG" "$APPCAST_FILE"

# ---------------------------------------------------------------------------
# Bump the Homebrew cask
# ---------------------------------------------------------------------------

if [ -f "$CASK_FILE" ]; then
    info "Bumping Casks/krit.rb to $VERSION"
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
              -e "s/^  sha256 \".*\"/  sha256 \"$DMG_SHA\"/" "$CASK_FILE"
fi

# ---------------------------------------------------------------------------
# Commit, tag and publish
# ---------------------------------------------------------------------------

# The tag must point at a commit that already carries the version bump, the
# appcast entry and the cask digest. Pushing the tag uploads that commit, so
# the GitHub release can be published from it before main moves. Order
# matters: shipped apps read appcast.xml from main the moment it lands, so
# main is pushed LAST, only after the release (and its DMG) is downloadable.
# Publishing the appcast first opens a window where the updater announces the
# version but the download 404s (the release is still a draft while assets
# upload), and every in-app update attempted in that window fails.
info "Committing release metadata"
assert_no_index_lock
git add "$INFO_PLIST" "$APPCAST_FILE" "$CASK_FILE" "$WHATSNEW_FILE" "$CHANGELOG_FILE"
assert_no_index_lock
git commit -m "chore: release $TAG

- bump CFBundleShortVersionString to $VERSION
- appcast entry for the Sparkle in-app update
- cask digest $DMG_SHA
- distribution mode $RELEASE_MODE

Autor: Leonardo Candiani"
RELEASE_COMMITTED=true

info "Creating git tag $TAG"
assert_no_index_lock
git tag -a "$TAG" -m "KRIT $TAG"

info "Publishing GitHub release $TAG with $DMG_NAME"
git push origin "$TAG"
# Create the release with notes + the small checksum first, then upload the DMG
# with retries. A slow/flaky link times a single multi-asset `gh release create`
# out mid-upload (a 40 MB+ DMG), leaving a draft with no installer; splitting the
# upload lets it resume without re-running the whole release.
gh release create "$TAG" "$SHA_FILE" \
    --draft \
    --title "KRIT $TAG" \
    --notes-file "$NOTES_TMP"
info "Uploading $DMG_NAME (retrying on a flaky link)"
dmg_uploaded=false
for attempt in 1 2 3 4 5; do
    if gh release upload "$TAG" "$DMG_PATH" --clobber \
        && gh release view "$TAG" --json assets --jq '[.assets[].name]' | grep -q "$DMG_NAME\""; then
        dmg_uploaded=true
        break
    fi
    info "  upload attempt $attempt did not complete; retrying"
    sleep 5
done
[ "$dmg_uploaded" = true ] || fail "DMG upload failed after retries. Finish with: gh release upload $TAG $DMG_PATH --clobber && gh release edit $TAG --draft=false && git push origin HEAD:refs/heads/main"

# Only now, with the DMG downloadable, publish the release and move main. This
# ordering is what keeps the updater from ever announcing a version whose
# download 404s.
gh release edit "$TAG" --draft=false

info "Publishing appcast (in-app updates go live)"
git push origin HEAD:refs/heads/main

ok "Released $TAG"
printf '\n'
printf '  Release:  https://github.com/leonardocandiani/krit/releases/tag/%s\n' "$TAG"
printf '  DMG:      %s\n' "$DMG_NAME"
printf '  sha256:   %s\n' "$DMG_SHA"
printf '  mode:     %s\n' "$RELEASE_MODE"
printf '  appcast:  entry for %s pushed to main (in-app updates live)\n' "$TAG"
