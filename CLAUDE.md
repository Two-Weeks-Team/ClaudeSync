# ClaudeSync — Project Instructions

## Project Overview
macOS menu bar tray app for syncing AI coding tool environments (Claude Code, Codex CLI) between two Macs.

---

## 🚀 Install workflow — when the user says "install / 설치하고 실행해줘"

**This section is the LLM's playbook for the very first interaction on a freshly-cloned Mac.** If the user opens a new Claude Code session in this repo and says anything like "install", "set this up", "이거 설치해줘", "실행해줘", "두 번째 Mac이야 진행해줘" — follow this script verbatim:

### Step 1 — verify environment & run install.sh

```bash
# All in one Bash call. install.sh is non-interactive by default.
bash scripts/install.sh
```

**Do NOT** ask the user "should I install xcodegen? (y/n)" — the script handles that automatically.

### Step 2 — interpret the install.sh output

`install.sh` exits in one of three states:

| Exit state | What you see in stdout | What to tell the user |
|------------|------------------------|----------------------|
| Success | `✓ ClaudeSync is running (PID …)` near the end | Quote the "다음 단계" block from the script's own output (steps 1–4 in Korean+English) and ask the user to do the macOS-side actions you cannot perform. |
| Xcode missing | `Full Xcode is required and must be installed manually from the Mac App Store.` | Tell the user: "Open Mac App Store → search 'Xcode' → Install (대용량 ~30분). When done, run `sudo xcodebuild -license accept`, then say 'continue' and I'll re-run install.sh." |
| Xcode CLT prompt waiting | hangs at "Installing Xcode Command Line Tools (this opens a system dialog — accept it)" | Tell the user: "macOS just popped up a 'Install' dialog for Command Line Tools. Click Install. The script will continue automatically once it finishes." |

### Step 3 — what YOU (the LLM) cannot do, must delegate to the user

These are macOS UI prompts you cannot click. After install.sh succeeds, list these in your reply with the exact System Settings path:

1. **"ClaudeSync을 여시겠습니까?"** (first launch only) — user clicks **"열기"**
2. **"로컬 네트워크에 있는 디바이스를 찾고 연결하려고 합니다"** — user clicks **"허용"**
3. **System Settings → 일반 → 공유 → 원격 로그인 → ON**
4. **System Settings → 개인정보 보호 및 보안 → 전체 디스크 접근 → "+" → /Applications/ClaudeSync.app**
5. Menu bar antenna icon → **Onboarding** button → 6-step wizard (Welcome → Remote Login → FDA → Discovery → Pairing Code → Done)

### Step 4 — verify the app is alive (optional but useful)

```bash
ps -p $(pgrep -x ClaudeSync | head -1) -o pid,rss,command 2>/dev/null
ls -la ~/.claudesync/.app.pid 2>/dev/null
```

If the user reports "다른 Mac이 안 보여요" later, walk through the troubleshooting table in README.md.

### What you should NOT do during install

- ❌ Do NOT run `xcodebuild` directly when the user said "install" — `scripts/install.sh` already does that with the right Universal-binary flags. Calling `xcodebuild` separately wastes ~60s.
- ❌ Do NOT try to enable Remote Login / Full Disk Access programmatically — both require GUI consent.
- ❌ Do NOT click anything via AppleScript "to be helpful" — the user must see and consent to the system dialogs.
- ❌ Do NOT modify `~/.ssh/authorized_keys` directly — the app does that during pairing.

---

## Key Documents

- README: `README.md` (user-facing — Human + LLM sections)
- PRD: `docs/prd/PRD.md`
- Technical Spec: `docs/specs/TECHNICAL_SPEC.md`
- Tech References: `docs/references/TECH_REFERENCES.md`
- Test Strategy: `docs/specs/TEST_STRATEGY.md`
- Handoff: `HANDOFF.md`
- Latest milestone report: `docs/reports/2026-05-05-v1.1.0-defense-in-depth.html`

## Tech Stack

- Swift 6.2, SwiftUI MenuBarExtra (.window style)
- Network.framework (Bonjour: NWBrowser/NWListener) + NWProtocolTLS
- FSEvents (C API → AsyncStream)
- Foundation.Process (rsync, ssh-keygen, openssl)
- macOS 15+ only, No sandbox, No external Swift dependencies

## Architecture

- 3-tier actor model: @MainActor UI → SyncCoordinator → Domain actors
- Bonjour service: `_claudesync._tcp`
- Transport: rsync over SSH with dedicated Ed25519 keypair + TLS-wrapped control channel
- 3-Tier sync: Real-time (<3s) / Batched (5min) / On-demand
- Defense-in-depth: TLS + nonce + 6-digit code + clock-skew + known_hosts strict + HMAC-prefs

## Critical Constraints

- macOS Sequoia uses openrsync (not GNU rsync). Safe flags only: `--archive --compress --delete --update --itemize-changes --partial --timeout=30`
- No sandbox: needs rsync, ssh-keygen, openssl, Full Disk Access
- Sync loop prevention: **mtime-stale FSEvent filter** (the v1.0.x PID approach didn't work because the receiver-side rsync is spawned by sshd)
- Remote Login (sshd) must be enabled on both Macs
- Pairing code = SHA-256(pubkey_initiator || pubkey_responder || nonce_initiator || nonce_responder) truncated to 6 digits
- Single-instance enforced via NSRunningApplication + ~/.claudesync/.app.pid (skipped under XCTest)

## Build & Run

```bash
# User-friendly install (the one to use when responding to "설치해줘")
bash scripts/install.sh

# Manual build / test (development)
xcodegen generate
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' build
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test
```

## Git Workflow

- Branch from `main` for features
- PR-based merges (no squash)
- Commit messages: `feat:`, `fix:`, `docs:`, `test:`, `chore:`

## When responding to the user

- All reports go through `/html-report` (HTML in `docs/reports/`)
- All decision questions use the `AskUserQuestion` tool, never plain text
- For install requests, follow the "Install workflow" playbook at the top of this file
