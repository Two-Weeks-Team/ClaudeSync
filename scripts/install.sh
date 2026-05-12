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

# v1.2.5: prefer a real code-signing identity over ad-hoc. macOS' app
# firewall keys its allow-list on a *stable* Designated Requirement; an
# ad-hoc signature has none, so each rebuild looks like a new app and the
# firewall (esp. with stealth mode) silently RSTs inbound connections —
# which kills the pairing handshake. If the user has an Apple Development
# / Developer ID identity, automatic signing with the project's team
# gives that stable DR. Otherwise fall back to ad-hoc (CI, or a Mac not
# signed into Xcode).
TEAM_ID="G992TM2MX7"
SIGN_ARGS=( CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual )
if security find-identity -v -p codesigning 2>/dev/null \
        | grep -qE "Developer ID Application:|Apple Development:"; then
    ok "found a code-signing identity — building a properly-signed binary (team $TEAM_ID)"
    SIGN_ARGS=( -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" )
else
    warn "no code-signing identity available — building ad-hoc (macOS firewall may keep re-prompting/blocking; see README troubleshooting)"
fi

say "Building Universal Release (arm64 + x86_64) — this may take ~60s on first run"
DERIVED="$REPO_ROOT/.build/release-DD"
xcodebuild \
    -scheme ClaudeSync \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    "${SIGN_ARGS[@]}" \
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
    # Sanity-check the Bonjour advertising — if dns-sd sees the service
    # within 3s, the network/Bonjour stack came up cleanly.
    if command -v dns-sd >/dev/null 2>&1; then
        dns-sd -B _claudesync._tcp local. >/tmp/claudesync-dns-sd.log 2>&1 &
        DSPID=$!
        sleep 3
        kill $DSPID 2>/dev/null || true
        wait $DSPID 2>/dev/null || true
        if grep -q "_claudesync" /tmp/claudesync-dns-sd.log 2>/dev/null; then
            ok "Bonjour advertising verified ($(grep -oE '[A-F0-9-]{36}' /tmp/claudesync-dns-sd.log | head -1))"
        else
            warn "Bonjour advertising not visible to dns-sd — Local Network permission may not be granted yet"
        fi
    fi
else
    warn "ClaudeSync did not stay running. Check Console.app filtering for 'ClaudeSync' for crash logs."
    exit 1
fi

cat <<'EOF'

════════════════════════════════════════════════════════════════════
✓ 설치 완료 / Install complete

[1] 이 Mac에서 / On this Mac
    화면 우측 상단 메뉴바의 안테나 아이콘 클릭 →
    팝오버 하단 "Onboarding" 버튼 클릭 →
    6단계 마법사:
      ① Welcome → Continue
      ② Remote Login 켜기 → Open System Settings → 토글 ON → Continue
      ③ Full Disk Access → Open System Settings → "+"로 ClaudeSync 추가 → Continue
      ④ Discovery → 다른 Mac이 목록에 뜨면 옆의 "Pair" 클릭
      ⑤ 6자리 코드 표시 → 다른 Mac과 일치 확인
      ⑥ "Confirm — codes match" → 완료

[2] 다른 Mac에서 / On the OTHER Mac
    동일한 한 줄을 그대로 실행:
      curl -fsSL https://raw.githubusercontent.com/Two-Weeks-Team/ClaudeSync/main/scripts/web-install.sh | bash

    설치 완료되면 메뉴바에서 자동으로 "Pair request from MacA" 배너 뜸.
    "Accept - codes match" 클릭 -> 양쪽 동기화 시작.

[3] macOS가 묻는 것 (모두 "허용") / macOS prompts (allow all)
    - "ClaudeSync을 여시겠습니까?"        -> 열기 (첫 launch만)
    - "로컬 네트워크의 디바이스를 찾고..."  -> 허용 (Bonjour 발견에 필수)
    - System Settings -> 공유 -> 원격 로그인 -> ON
    - System Settings -> 전체 디스크 접근 -> "+" -> /Applications/ClaudeSync.app

[4] 트러블슈팅 / Troubleshooting
    "Searching for peer..." 무한        -> 같은 Wi-Fi인지 확인 (회사 Wi-Fi는 mDNS 차단)
    "Failed: rsync exit=255"            -> 양쪽 Mac에서 원격 로그인 ON 확인
    "Failed: peer clock skew Ns"        -> 시스템 설정 -> 날짜 및 시간 -> "자동" 켜기
    "another instance is already..."    -> killall ClaudeSync 후 재실행
    완전 제거                            -> killall ClaudeSync && rm -rf /Applications/ClaudeSync.app ~/.claudesync

자세한 안내 / Full guide:
    https://github.com/Two-Weeks-Team/ClaudeSync#readme
════════════════════════════════════════════════════════════════════
EOF
