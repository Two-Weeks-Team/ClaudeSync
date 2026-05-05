#!/usr/bin/env bash
#
# package.sh — produce a distributable ClaudeSync.dmg.
#
# Pipeline:
#   1. Release Universal build  (scripts/release-build.sh)
#   2. Optional: codesign with Developer ID  (env: CODESIGN_IDENTITY)
#   3. Stage into a clean dmg-source/ folder with a symlink to /Applications
#   4. Create UDIF zlib-compressed DMG via hdiutil
#   5. Optional: notarize + staple                (env: NOTARY_PROFILE)
#
# Required tools: xcodebuild, hdiutil, codesign (built-in).
# Optional tools: xcrun notarytool (Apple Developer required).
#
# Environment variables (all optional — script degrades gracefully):
#   CODESIGN_IDENTITY  — e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     — keychain profile name set up via `xcrun notarytool store-credentials`
#
# Output: dist/ClaudeSync-<version>.dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST_DIR="$REPO_ROOT/dist"
STAGING_DIR="$REPO_ROOT/.build/dmg-source"
mkdir -p "$DIST_DIR"

# 1. Release build.
bash "$REPO_ROOT/scripts/release-build.sh"
APP_PATH="$REPO_ROOT/.build/release-DD/Build/Products/Release/ClaudeSync.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
DMG_NAME="ClaudeSync-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# 2. Codesign (optional).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo ""
    echo "▶︎ Codesigning with: $CODESIGN_IDENTITY"
    codesign --force --options runtime \
        --entitlements ClaudeSync/Resources/ClaudeSync.entitlements \
        --sign "$CODESIGN_IDENTITY" \
        --timestamp \
        "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
    echo "⚠️  CODESIGN_IDENTITY not set — DMG will be ad-hoc signed only."
    echo "   Set it for distribution, e.g.:"
    echo "     export CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
fi

# 3. Stage.
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# 4. DMG.
echo ""
echo "▶︎ Building DMG: $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "ClaudeSync $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

# 5. Sign + notarize the DMG (optional).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo ""
    echo "▶︎ Submitting to Apple notary service (profile: $NOTARY_PROFILE)…"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "▶︎ Stapling notarization ticket…"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "⚠️  NOTARY_PROFILE not set — DMG is signed but NOT notarized."
    echo "   Without notarization Gatekeeper will block download-and-open."
    echo "   To set up:"
    echo "     xcrun notarytool store-credentials ClaudeSync \\"
    echo "       --apple-id you@example.com --team-id TEAMID --password app-specific-pwd"
    echo "     export NOTARY_PROFILE=ClaudeSync"
fi

echo ""
echo "✅ Package complete:"
ls -lh "$DMG_PATH"
echo ""
echo "Distribute via GitHub Release or direct download."
