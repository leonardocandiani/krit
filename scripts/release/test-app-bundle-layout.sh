#!/usr/bin/env bash

set -euo pipefail

APP_PATH="${1:-/Applications/KRIT.app}"
RESOURCE_DIR="$APP_PATH/Contents/Resources"
EXECUTABLE="$APP_PATH/Contents/MacOS/KRIT"
BUILD_PATHS_TO_HIDE="${KRIT_BUILD_PATHS_TO_HIDE:-}"
REPORT="$(mktemp /tmp/krit-bundle-runtime-report.XXXXXX)"
LOG="$(mktemp /tmp/krit-bundle-runtime-log.XXXXXX)"
RUNTIME_PID=""
hiddenPaths=()
originalPaths=()

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [ -s "$LOG" ] && tail -80 "$LOG" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT INT HUP TERM
    if [ -n "$RUNTIME_PID" ] && kill -0 "$RUNTIME_PID" 2>/dev/null; then
        kill "$RUNTIME_PID" 2>/dev/null || true
        wait "$RUNTIME_PID" 2>/dev/null || true
    fi
    for ((index=${#hiddenPaths[@]} - 1; index >= 0; index--)); do
        hidden="${hiddenPaths[$index]}"
        original="${originalPaths[$index]}"
        [ -e "$hidden" ] || continue
        if [ -e "$original" ]; then
            printf 'FAIL: build path was recreated while hidden; preserved old cache at %s\n' \
                "$hidden" >&2
            status=1
        elif ! mv "$hidden" "$original"; then
            printf 'FAIL: could not restore build path %s from %s\n' "$original" "$hidden" >&2
            status=1
        fi
    done
    rm -f "$REPORT" "$LOG"
    exit "$status"
}

handle_signal() {
    exit "$1"
}

trap 'handle_signal 130' INT
trap 'handle_signal 129' HUP
trap 'handle_signal 143' TERM
trap cleanup EXIT

[ -d "$APP_PATH" ] || fail "app bundle not found: $APP_PATH"
[ -d "$RESOURCE_DIR" ] || fail "resource directory not found: $RESOURCE_DIR"
[ -x "$EXECUTABLE" ] || fail "app executable not found: $EXECUTABLE"
[ -n "$BUILD_PATHS_TO_HIDE" ] || \
    fail "KRIT_BUILD_PATHS_TO_HIDE must name at least one build path"

resourceBundles=()
for bundle in "$RESOURCE_DIR"/*.bundle; do
    [ -d "$bundle" ] && resourceBundles+=("$bundle")
done
[ "${#resourceBundles[@]}" -eq 2 ] || \
    fail "expected exactly 2 SwiftPM resource bundles, found ${#resourceBundles[@]}"

for required in Krit_KritKit.bundle KeyboardShortcuts_KeyboardShortcuts.bundle; do
    [ -d "$RESOURCE_DIR/$required" ] || fail "required resource bundle missing: $required"
done

for bundle in "${resourceBundles[@]}"; do
    name="$(basename "$bundle")"
    accessorPath="$APP_PATH/$name"
    [ ! -e "$accessorPath" ] && [ ! -L "$accessorPath" ] || \
        fail "nonstandard resource entry found at app root: $accessorPath"
done

codesign --verify --deep --strict "$APP_PATH" 2>"$LOG" || fail "code signature verification failed"

IFS=':' read -r -a candidates <<< "$BUILD_PATHS_TO_HIDE"
for path in "${candidates[@]}"; do
    [ -n "$path" ] || continue
    if [ -e "$path" ]; then
        hidden="$path.krit-runtime-probe.$$"
        [ ! -e "$hidden" ] || fail "temporary hide path already exists: $hidden"
        originalPaths+=("$path")
        hiddenPaths+=("$hidden")
        mv "$path" "$hidden"
    fi
done
[ "${#hiddenPaths[@]}" -gt 0 ] || \
    fail "none of the requested build paths existed: $BUILD_PATHS_TO_HIDE"

harnessMarker="$(/usr/libexec/PlistBuddy -c 'Print :KritUIHarnessBuild' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [ "$harnessMarker" = "true" ]; then
    env KRIT_UI_TEST=1 KRIT_UI_SCENARIO="preferences|$REPORT" "$EXECUTABLE" >"$LOG" 2>&1 &
    RUNTIME_PID=$!
    for _ in $(seq 1 900); do
        [ -s "$REPORT" ] && break
        kill -0 "$RUNTIME_PID" 2>/dev/null || break
        sleep 0.1
    done
    [ -s "$REPORT" ] || fail "harness exited before producing the Preferences report"
    python3 - "$REPORT" <<'PY' || fail "Preferences runtime scenario failed"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)

assert report.get("allPass") is True, report
assert report.get("renderFallbackCount") == 0, report
assert report.get("sectionCount") == 9, report
PY
    for _ in $(seq 1 100); do
        kill -0 "$RUNTIME_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$RUNTIME_PID" 2>/dev/null && \
        fail "harness did not exit within ten seconds after writing its report"
    set +e
    wait "$RUNTIME_PID"
    runtimeStatus=$?
    set -e
    RUNTIME_PID=""
    [ "$runtimeStatus" -eq 0 ] || fail "harness exited with status $runtimeStatus"
else
    "$EXECUTABLE" --krit-verify-bundle-runtime >"$LOG" 2>&1 &
    RUNTIME_PID=$!
    for _ in $(seq 1 150); do
        kill -0 "$RUNTIME_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$RUNTIME_PID" 2>/dev/null && \
        fail "app bundle probe did not exit within fifteen seconds"
    set +e
    wait "$RUNTIME_PID"
    runtimeStatus=$?
    set -e
    RUNTIME_PID=""
    [ "$runtimeStatus" -eq 0 ] || fail "app bundle probe exited with status $runtimeStatus"
    grep -Fq "Shortcuts resource runtime probe passed" "$LOG" || \
        fail "app bundle probe did not confirm the Shortcuts runtime path"
fi

printf 'PASS: %s keeps %s resource bundles in the standard layout and launches without build-path fallbacks\n' \
    "$APP_PATH" "${#resourceBundles[@]}"
