#!/usr/bin/env bash
#
# update.sh — pull the latest committed code and (re)install ClaudeSync
# on THIS Mac.
#
#   cd ClaudeSync          # the clone you already have
#   bash scripts/update.sh
#
# Use this on a Mac that has already cloned the repo (e.g. the second
# Mac in a two-Mac setup) so both machines run the SAME version and can
# pair / auto-pair without version drift. Idempotent — safe to re-run.
#
# What it does:
#   1. git pull --ff-only        (fast-forward to origin/<current branch>)
#   2. killall ClaudeSync        (stop the running tray, if any)
#   3. bash scripts/install.sh   (rebuild Universal Release → /Applications → launch)
#   4. report iCloud Drive status — auto-pair needs it ON on BOTH Macs;
#      otherwise the visual 6-digit code flow is used (still works).

set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
say()  { echo "${BLUE}▶︎${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET}  $*"; }
err()  { echo "${RED}✗${RESET} $*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "ClaudeSync is macOS-only. uname=$(uname -s)"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -d .git ]]; then
    err "$REPO_ROOT is not a git clone. Use scripts/web-install.sh for a fresh machine."
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
say "Updating clone at $REPO_ROOT (branch: $BRANCH)…"
BEFORE="$(git rev-parse --short HEAD)"
git pull --ff-only
AFTER="$(git rev-parse --short HEAD)"
if [[ "$BEFORE" == "$AFTER" ]]; then
    ok "already up to date at $AFTER"
else
    ok "fast-forwarded $BEFORE → $AFTER"
fi

if pgrep -x ClaudeSync >/dev/null 2>&1; then
    say "Stopping running ClaudeSync…"
    killall ClaudeSync 2>/dev/null || true
    sleep 1
fi

say "Reinstalling…"
bash scripts/install.sh

# ─── auto-pair preflight: iCloud Drive must be ON on BOTH Macs ────────
echo
ICLOUD_ROOT="$HOME/Library/Mobile Documents/com.apple.CloudDocs"
if [[ -d "$ICLOUD_ROOT" ]]; then
    ok "iCloud Drive is ON — auto-pair channel available (needs ON on the OTHER Mac too)"
else
    warn "iCloud Drive is OFF on this Mac — auto-pair will NOT work."
    echo "    Turn it on:  Apple menu → System Settings → [your name] → iCloud → iCloud Drive → ON"
    echo "    Without it, pairing still works via the visual 6-digit code in the Onboarding wizard."
fi

echo
ok "Done. Now open the menu-bar antenna icon → Onboarding (once per Mac)."
echo "   Repeat the same on the OTHER Mac:  cd ClaudeSync && bash scripts/update.sh"
