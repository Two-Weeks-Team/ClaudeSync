#!/usr/bin/env bash
#
# web-install.sh — for users who want a single line, no git knowledge.
#
# On either Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/Two-Weeks-Team/ClaudeSync/main/scripts/web-install.sh | bash
#
# Clones the repo to ~/.claudesync/source (or pulls if it exists), then
# delegates to scripts/install.sh which handles xcodegen → build →
# /Applications → launch.

set -euo pipefail

REPO_URL="${CLAUDESYNC_REPO_URL:-https://github.com/Two-Weeks-Team/ClaudeSync.git}"
SRC_DIR="${CLAUDESYNC_SOURCE_DIR:-$HOME/.claudesync/source}"

BLUE=$'\033[34m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
say()  { echo "${BLUE}▶︎${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
err()  { echo "${RED}✗${RESET} $*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "ClaudeSync is macOS-only."
    exit 1
fi

# Make sure git is here. macOS triggers the CLT installer if `git` is
# called with no Xcode CLT installed.
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
