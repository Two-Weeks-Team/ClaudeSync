#!/usr/bin/env bash
#
# web-install.sh — for users who want a single line, no Xcode, no Homebrew,
# no git. Tries the pre-built GitHub Release DMG first; only falls back to
# building from source when no Release exists OR the user explicitly opts in.
#
# On either Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/Two-Weeks-Team/ClaudeSync/main/scripts/web-install.sh | bash
#
# Path A — DMG (default, no Xcode required):
#   1. Fetch the latest GitHub Release that has a *.dmg asset
#   2. Verify SHA-256 if a sidecar is published
#   3. Mount, copy ClaudeSync.app to /Applications, strip quarantine
#   4. Launch
#
# Path B — Source build (auto-fallback when DMG missing OR
# CLAUDESYNC_FORCE_SOURCE=1):
#   Clone the repo and exec scripts/install.sh, which handles
#   xcodegen + xcodebuild + install.
#
# Environment overrides:
#   CLAUDESYNC_REPO_URL       default: https://github.com/Two-Weeks-Team/ClaudeSync.git
#   CLAUDESYNC_REPO_API       default: https://api.github.com/repos/Two-Weeks-Team/ClaudeSync
#   CLAUDESYNC_FORCE_SOURCE   set to 1 to skip the DMG path
#   CLAUDESYNC_SOURCE_DIR     default: ~/.claudesync/source

set -euo pipefail

REPO_URL="${CLAUDESYNC_REPO_URL:-https://github.com/Two-Weeks-Team/ClaudeSync.git}"
REPO_API="${CLAUDESYNC_REPO_API:-https://api.github.com/repos/Two-Weeks-Team/ClaudeSync}"
SRC_DIR="${CLAUDESYNC_SOURCE_DIR:-$HOME/.claudesync/source}"
FORCE_SOURCE="${CLAUDESYNC_FORCE_SOURCE:-0}"

BLUE=$'\033[34m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
say()  { echo "${BLUE}▶︎${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET}  $*"; }
err()  { echo "${RED}✗${RESET} $*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "ClaudeSync is macOS-only."
    exit 1
fi

MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MACOS_MAJOR < 15 )); then
    err "ClaudeSync requires macOS 15 (Sequoia) or newer. Current: $(sw_vers -productVersion)"
    exit 1
fi

ARCH=$(uname -m)
ok "macOS $(sw_vers -productVersion) on $ARCH"

# ─── Path A: try the GitHub Release DMG ──────────────────────────────
try_dmg_install() {
    say "Looking up the latest GitHub Release with a DMG asset…"
    # Use the public API; no auth needed for public repos. Filter for the
    # first non-prerelease that has an asset whose name ends in .dmg.
    local releases_json dmg_url dmg_name sha_url
    if ! releases_json=$(curl -fsSL "$REPO_API/releases" 2>/dev/null); then
        warn "Could not reach GitHub API — falling back to source build"
        return 1
    fi

    # Use Python (always present on macOS) to parse JSON without jq.
    # Pick the first release that:
    #   * isn't a draft,
    #   * isn't a prerelease,
    #   * has at least one .dmg asset.
    read -r dmg_url dmg_name sha_url <<EOF || true
$(/usr/bin/python3 - <<'PY' "$releases_json"
import json, sys
data = json.loads(sys.argv[1])
for rel in data:
    if rel.get("draft") or rel.get("prerelease"):
        continue
    dmg = next((a for a in rel.get("assets", [])
                if a["name"].lower().endswith(".dmg")), None)
    if not dmg:
        continue
    sha = next((a for a in rel.get("assets", [])
                if a["name"] == dmg["name"] + ".sha256"), None)
    print(dmg["browser_download_url"], dmg["name"],
          (sha or {}).get("browser_download_url", ""))
    break
PY
)
EOF

    if [[ -z "$dmg_url" ]]; then
        warn "No suitable .dmg asset found in any Release — falling back to source build"
        return 1
    fi

    ok "Found DMG: $dmg_name"
    local tmp="$RUNNER_TEMP_DIR"
    mkdir -p "$tmp"
    say "Downloading ${dmg_name}…"
    curl -fSL --progress-bar "$dmg_url" -o "$tmp/$dmg_name"

    if [[ -n "$sha_url" ]]; then
        say "Verifying SHA-256…"
        curl -fsSL "$sha_url" -o "$tmp/$dmg_name.sha256"
        cd "$tmp"
        if ! shasum -a 256 -c "$dmg_name.sha256"; then
            err "SHA-256 mismatch — refusing to install. The download may be corrupted or tampered with."
            cd - >/dev/null
            return 1
        fi
        cd - >/dev/null
        ok "SHA-256 verified"
    else
        warn "No SHA-256 sidecar published for this release — proceeding without integrity check"
    fi

    say "Mounting DMG…"
    local mountpoint
    mountpoint=$(hdiutil attach "$tmp/$dmg_name" -nobrowse -noverify -noautoopen \
                 | tail -1 | awk -F'\t' '{print $NF}')
    if [[ -z "$mountpoint" || ! -d "$mountpoint/ClaudeSync.app" ]]; then
        err "DMG did not contain ClaudeSync.app at the expected path"
        return 1
    fi

    if [[ -d /Applications/ClaudeSync.app ]]; then
        say "Stopping any running instance and replacing existing /Applications/ClaudeSync.app"
        pkill -x ClaudeSync 2>/dev/null || true
        sleep 1
        rm -rf /Applications/ClaudeSync.app
    fi
    say "Copying to /Applications…"
    cp -R "$mountpoint/ClaudeSync.app" /Applications/
    hdiutil detach "$mountpoint" >/dev/null

    # Ad-hoc-signed builds inherit a quarantine xattr from the DMG. Strip
    # it so first-launch doesn't get blocked by Gatekeeper. (Notarized
    # DMGs don't strictly need this but the call is harmless.)
    xattr -dr com.apple.quarantine /Applications/ClaudeSync.app 2>/dev/null || true
    ok "Installed at /Applications/ClaudeSync.app"

    say "Launching…"
    open -g /Applications/ClaudeSync.app
    sleep 2
    if pgrep -x ClaudeSync >/dev/null 2>&1; then
        local pid; pid=$(pgrep -x ClaudeSync | head -1)
        ok "ClaudeSync is running (PID $pid)"
    else
        warn "ClaudeSync did not stay running — Console.app may have details"
    fi

    cat <<MSG

════════════════════════════════════════════════════════════════════
✓ 설치 완료 / Install complete (from DMG, no Xcode used)

다음 단계 / Next steps:
  1) 메뉴바 우상단 안테나 아이콘 클릭 -> 팝오버 하단 "Onboarding" 클릭
  2) 6단계 마법사 따라서 권한 부여 + 페어링
  3) 다른 Mac에서 똑같이 한 줄 실행:
     curl -fsSL https://raw.githubusercontent.com/Two-Weeks-Team/ClaudeSync/main/scripts/web-install.sh | bash

자세한 안내 / Full guide:
  https://github.com/Two-Weeks-Team/ClaudeSync#readme
════════════════════════════════════════════════════════════════════
MSG
    return 0
}

# ─── Path B: source build fallback ───────────────────────────────────
fallback_to_source() {
    say "Falling back to source build (this needs Xcode)"
    if ! command -v git >/dev/null 2>&1; then
        say "git not found — triggering Xcode Command Line Tools installer"
        xcode-select --install 2>/dev/null || true
        until command -v git >/dev/null 2>&1; do
            sleep 5
        done
        ok "git available"
    fi

    mkdir -p "$(dirname "$SRC_DIR")"
    if [[ -d "$SRC_DIR/.git" ]]; then
        say "Updating existing checkout at $SRC_DIR"
        git -C "$SRC_DIR" fetch --quiet origin
        git -C "$SRC_DIR" reset --hard origin/main --quiet
    else
        say "Cloning $REPO_URL → $SRC_DIR"
        git clone --quiet "$REPO_URL" "$SRC_DIR"
    fi

    ok "Source ready, handing off to install.sh"
    echo ""
    exec bash "$SRC_DIR/scripts/install.sh"
}

# ─── main ────────────────────────────────────────────────────────────
RUNNER_TEMP_DIR=$(mktemp -d -t claudesync-install)
trap 'rm -rf "$RUNNER_TEMP_DIR"' EXIT

if [[ "$FORCE_SOURCE" == "1" ]]; then
    say "CLAUDESYNC_FORCE_SOURCE=1 — skipping DMG path"
    fallback_to_source
fi

if try_dmg_install; then
    exit 0
fi

fallback_to_source
