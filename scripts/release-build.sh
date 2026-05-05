#!/usr/bin/env bash
#
# release-build.sh — produce a Release build of ClaudeSync.app, verify the
# Universal binary slices, and print the bundle path.
#
# Does NOT codesign or notarize — those steps need the user's Developer ID
# certificate and Apple ID. See package.sh / sign-and-notarize.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="ClaudeSync"
CONFIGURATION="Release"

# Use a clean per-invocation derived data dir so we don't pick up Debug slices.
DERIVED="$REPO_ROOT/.build/release-DD"
rm -rf "$DERIVED"

echo "▶︎ Building $SCHEME ($CONFIGURATION) — Universal binary"
xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build \
    | xcbeautify --quiet 2>/dev/null || true

APP_PATH="$DERIVED/Build/Products/$CONFIGURATION/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ Build did not produce $APP_PATH" >&2
    exit 1
fi

EXEC_PATH="$APP_PATH/Contents/MacOS/$SCHEME"
echo ""
echo "▶︎ Bundle: $APP_PATH"
echo "▶︎ Architectures:"
lipo -info "$EXEC_PATH"

echo ""
echo "▶︎ Bundle size:"
du -sh "$APP_PATH"

echo ""
echo "▶︎ Mach-O slices:"
file "$EXEC_PATH"

echo ""
echo "✅ Release build complete."
echo "   Bundle: $APP_PATH"
echo "   Next:   scripts/measure-footprint.sh \"$APP_PATH\""
