#!/usr/bin/env bash
#
# install.sh — one-shot bootstrap for ClaudeSync.
#
#   git clone https://github.com/Two-Weeks-Team/ClaudeSync.git
#   cd ClaudeSync
#   bash scripts/install.sh
#
# Verifies prerequisites, installs missing build tools (with consent),
# generates the Xcode project, builds a Universal Release binary,
# strips the Gatekeeper quarantine flag so the .app launches without
# a "verified developer" prompt, copies it to /Applications, and
# launches it. Idempotent — safe to re-run.
#
# Designed so the SECOND Mac in a two-Mac setup can do "git clone +
# bash scripts/install.sh" and reach a working menu-bar tray ready
# to pair, without any prior Xcode/Homebrew knowledge.

set -euo pipefail

# ─── pretty output ───────────────────────────────────────────────────
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
say()  { echo "${BLUE}▶︎${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET}  $*"; }
err()  { echo "${RED}✗${RESET} $*" >&2; }

# ─── 0) sanity ───────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    err "ClaudeSync is macOS-only. uname=$(uname -s)"
    exit 1
fi
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MACOS_MAJOR < 15 )); then
    err "ClaudeSync requires macOS 15 (Sequoia) or newer. Current: $(sw_vers -productVersion)"
    exit 1
fi
ARCH=$(uname -m)
ok "macOS $(sw_vers -productVersion) on $ARCH — ready"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ─── 1) prerequisites ────────────────────────────────────────────────
say "Checking prerequisites…"

MISSING=()
if ! xcode-select -p >/dev/null 2>&1; then
    MISSING+=("Xcode Command Line Tools")
fi
HAS_XCODEBUILD=0
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
    HAS_XCODEBUILD=1
fi
if (( HAS_XCODEBUILD == 0 )); then
    MISSING+=("Xcode (full app, not just CLT)")
fi
if ! command -v xcodegen >/dev/null 2>&1; then
    MISSING+=("xcodegen")
fi

if (( ${#MISSING[@]} > 0 )); then
    warn "Missing prerequisites:"
    for m in "${MISSING[@]}"; do echo "    - $m"; done
    echo ""

    # v1.1.1: default to non-interactive YES so a freshly-cloned Mac
    # only needs `bash scripts/install.sh` (no prompt to answer).
    # Override with CLAUDESYNC_INTERACTIVE=1 to get the [y/N] prompt back.
    DO_INSTALL=1
    if [[ "${CLAUDESYNC_INTERACTIVE:-}" == "1" ]]; then
        read -r -p "Install xcodegen automatically via Homebrew? [Y/n] " yn
        if [[ "$yn" =~ ^[Nn]$ ]]; then
            DO_INSTALL=0
        fi
    else
        say "Auto-installing missing tools (set CLAUDESYNC_INTERACTIVE=1 to be asked first)"
    fi

    if (( DO_INSTALL == 1 )); then
        # 1) Xcode CLT — required by everything else.
        for m in "${MISSING[@]}"; do
            if [[ "$m" == "Xcode Command Line Tools" ]]; then
                say "Installing Xcode Command Line Tools (this opens a system dialog — accept it)"
                xcode-select --install 2>/dev/null || true
                # Block until the user accepts and the install finishes.
                until xcode-select -p >/dev/null 2>&1; do
                    sleep 5
                done
                ok "Xcode Command Line Tools installed"
            fi
        done
        # 2) Full Xcode — cannot be installed via CLI; must be Mac App Store.
        if (( HAS_XCODEBUILD == 0 )); then
            err "Full Xcode is required and must be installed manually from the Mac App Store."
            err "After installing Xcode, accept its license:  sudo xcodebuild -license accept"
            err "Then re-run:  bash scripts/install.sh"
            exit 1
        fi
        # 3) Homebrew (needed for xcodegen).
        if ! command -v brew >/dev/null 2>&1; then
            say "Installing Homebrew (this is the official, non-interactive bootstrap from brew.sh)"
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            # Add brew to PATH for this session.
            if [[ -x /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -x /usr/local/bin/brew ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
        fi
        # 4) xcodegen.
        if ! command -v xcodegen >/dev/null 2>&1; then
            say "Installing xcodegen via Homebrew"
            brew install xcodegen
        fi
        ok "All prerequisites satisfied"
    else
        err "Cannot proceed without xcodegen. Aborting."
        exit 1
    fi
fi

# Optional deps — note but don't block.
if ! command -v rsync >/dev/null 2>&1; then
    warn "rsync not found in PATH (macOS ships /usr/bin/rsync as openrsync). ClaudeSync will fall back to /usr/bin/rsync."
else
    ok "$(rsync --version 2>/dev/null | head -1)"
fi
HAS_OPENSSL=0
for c in /opt/homebrew/bin/openssl /usr/local/bin/openssl /usr/bin/openssl; do
    if [[ -x "$c" ]]; then HAS_OPENSSL=1; OPENSSL_PATH="$c"; break; fi
done
if (( HAS_OPENSSL == 1 )); then
    ok "openssl at $OPENSSL_PATH"
else
    warn "openssl not found — TLS for the Bonjour control channel will fall back to plaintext (the app still works; the visual code + nonce + known_hosts layers protect you)."
fi

# Remote Login (sshd) check — informational only since the app's
# onboarding will surface this and offer a System Settings deep link.
if ! pgrep -x sshd >/dev/null 2>&1 && ! launchctl print system 2>/dev/null | grep -q "com.openssh.sshd"; then
    warn "Remote Login (sshd) appears disabled. Enable later in System Settings → General → Sharing → Remote Login. The Onboarding window will guide you."
fi

# ─── 2) generate + build ─────────────────────────────────────────────
say "Generating Xcode project…"
xcodegen generate >/dev/null
ok "project generated"

say "Building Universal Release (arm64 + x86_64) — this may take ~60s on first run"
DERIVED="$REPO_ROOT/.build/release-DD"
xcodebuild \
    -scheme ClaudeSync \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    clean build \
    -quiet 2>&1 | tail -3 || {
        err "Build failed. Re-run with verbose output:"
        echo "  xcodebuild -scheme ClaudeSync -configuration Release build"
        exit 1
    }
APP_BUILT="$DERIVED/Build/Products/Release/ClaudeSync.app"
if [[ ! -d "$APP_BUILT" ]]; then
    err "Build succeeded but $APP_BUILT not found"
    exit 1
fi
ok "built $APP_BUILT"

# ─── 3) install to /Applications ─────────────────────────────────────
DEST="/Applications/ClaudeSync.app"
if [[ -d "$DEST" ]]; then
    say "Replacing existing /Applications/ClaudeSync.app"
    # Stop any running instance so we can overwrite it.
    pkill -x ClaudeSync 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
fi
say "Copying to /Applications…"
cp -R "$APP_BUILT" "$DEST"

# Strip the quarantine flag so Gatekeeper doesn't block the first launch.
# Safe — we built locally, not downloaded from the internet, but the
# build artifact may still inherit a quarantine xattr.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ok "installed at $DEST (quarantine flag cleared)"

# ─── 4) launch ───────────────────────────────────────────────────────
say "Launching ClaudeSync…"
open -g "$DEST"
sleep 2

# Verify it actually started and registered the menu bar item.
if pgrep -x ClaudeSync >/dev/null 2>&1; then
    PID=$(pgrep -x ClaudeSync | head -1)
    ok "ClaudeSync is running (PID $PID)"
    # Sanity-check the Bonjour advertising — if dns-sd has it within 5s,
    # the network/Bonjour stack came up cleanly.
    if command -v dns-sd >/dev/null 2>&1; then
        if dns-sd -B _claudesync._tcp local. 2>&1 &
        DSPID=$!
        sleep 3
        kill $DSPID 2>/dev/null || true
        wait 2>/dev/null || true
        echo ""
        ok "Bonjour advertising verified (see dns-sd output above for the registered UUID)"
    fi
else
    warn "ClaudeSync did not stay running. Check Console.app filtering for 'ClaudeSync' for crash logs."
    exit 1
fi

cat <<'EOF'

────────────────────────────────────────────────────────────────────
✓ Install complete.

Next on THIS Mac:
  1) Click the antenna icon in your menu bar (top-right of the screen)
  2) Click "Onboarding" to grant Remote Login + Full Disk Access permissions
  3) Wait for the OTHER Mac to appear under "Peers on this network"
  4) Click "Pair" → confirm the 6-digit code matches on both screens

Next on the OTHER Mac:
  Repeat the same:
      git clone https://github.com/Two-Weeks-Team/ClaudeSync.git
      cd ClaudeSync && bash scripts/install.sh

Then on the OTHER Mac, you'll see the pair-request banner appear in the
menu bar popover. Confirm the same 6-digit code → done. Sync starts
immediately and survives both Macs restarting.

Troubleshooting:
  - "Searching for peer..." forever  → both Macs on same Wi-Fi? mDNS allowed?
  - rsync exit 255                    → Remote Login enabled in System Settings?
  - clock skew error                  → enable "Set time and date automatically"
  - Full uninstall: pkill -x ClaudeSync && rm -rf /Applications/ClaudeSync.app ~/.claudesync
────────────────────────────────────────────────────────────────────
EOF
