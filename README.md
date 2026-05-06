# ClaudeSync

> macOS 메뉴바 앱. 두 Mac 간 Claude Code · Claude Desktop · Codex CLI의 설정 / 세션 / 메모리를 자동 동기화합니다.

[![tests](https://img.shields.io/badge/tests-214%20passing-3fb950)]() [![macOS](https://img.shields.io/badge/macOS-15%2B-58a6ff)]() [![arch](https://img.shields.io/badge/arch-arm64%20%2B%20x86__64-d2a8ff)]() [![version](https://img.shields.io/badge/version-1.1.0-d29922)]()

> ⚠️ **현재 상태**: 1:1 두 Mac 동기화. ad-hoc 서명 (Developer ID + 공증은 v1.2 예정). 외부 라이브러리 0, 외부 서비스 0.

---

## 목차

- [설치 — 세 가지 path 중 하나](#설치--세-가지-path-중-하나)
  - [Path A — Claude Code에게 위임 ⭐](#path-a--claude-code또는-다른-ai-agent에게-위임--가장-게으른-방법)
  - [Path B — 한 줄 web installer](#path-b--한-줄-web-installer-claude-code-없어도-ok)
  - [Path C — 직접 수동](#path-c--git-clone-후-직접-수동-개발자용)
- [전체 흐름 — 두 Mac 처음부터 끝까지](#전체-흐름--두-mac-처음부터-끝까지)
- [무엇을 하나](#무엇을-하나)
- [🧑 For Human — 사용자 가이드](#-for-human--사용자-가이드)
- [🤖 For LLM — Claude Code 등 AI 도구로 작업할 때](#-for-llm--claude-code-등-ai-도구로-작업할-때)

---

## 설치 — 세 가지 path 중 하나

### Path A — Claude Code(또는 다른 AI agent)에게 위임 ⭐ 가장 게으른 방법

다른 Mac에서 git clone만 한 후 그 폴더에서 Claude Code를 열고 한 마디:

```
이 프로젝트 설치해서 실행해줘
```

Claude Code가 자동으로 `CLAUDE.md`의 "Install workflow" 섹션을 읽고 다음을 처리합니다:

1. `bash scripts/install.sh` 실행 (Xcode CLT / Homebrew / xcodegen 자동)
2. Universal Release 빌드 + `/Applications/ClaudeSync.app` 설치 + launch
3. macOS가 묻는 GUI prompt들 (Remote Login, FDA, Local Network)을 사용자에게 명시적으로 안내
4. Onboarding 6단계 마법사로 가이드

LLM이 못 하는 부분 (시스템 다이얼로그 클릭, Onboarding 버튼 클릭)은 사용자에게 정확히 어디를 클릭하라고 안내합니다.

> 💡 사전 요구: 다른 Mac에 Claude Code가 설치되어 있어야 함 + git clone이 끝나 있어야 함. Claude Code가 없으면 Path B 또는 C를 사용.

### Path B — 한 줄 web installer (Xcode 없어도 OK ⭐)

**두 Mac 각각의 터미널에서 똑같이 한 번씩**:

```bash
curl -fsSL https://raw.githubusercontent.com/Two-Weeks-Team/ClaudeSync/main/scripts/web-install.sh | bash
```

이 한 줄이 자동으로:

1. **GitHub Releases에서 latest .dmg 다운로드** (SHA-256 verification)
2. mount → `/Applications/ClaudeSync.app` 복사 → quarantine 제거
3. launch + 메뉴바 등장 확인

**Xcode/Homebrew/git 모두 없어도 동작합니다** — GitHub Actions가 미리 빌드한 Universal binary DMG를 받아서 설치만 합니다. 빈 macOS 15 Mac에서도 약 30초 안에 완료.

> 만약 GitHub Release가 아직 없거나 다운로드 실패하면, 자동으로 source build path(Xcode 필요)로 fallback. 강제로 source build 원하면 `CLAUDESYNC_FORCE_SOURCE=1` 환경변수.

이 한 줄이 자동으로:

| 단계 | 무엇 | 사용자 입력 |
|------|------|-----------|
| 1 | Xcode Command Line Tools 설치 (없으면) | macOS 시스템 다이얼로그에서 "설치" |
| 2 | git → 소스 clone (`~/.claudesync/source`) | 없음 |
| 3 | Homebrew 설치 (없으면 비대화형) | 없음 |
| 4 | xcodegen 설치 | 없음 |
| 5 | Universal Release 빌드 (~60초) | 없음 |
| 6 | `/Applications/ClaudeSync.app` 설치 + Gatekeeper quarantine 제거 | 없음 |
| 7 | 앱 launch | 없음 |

종료 후 터미널에 다음 단계 안내가 한국어로 출력됩니다.

> ⚠️ **Xcode 자체는 자동 설치 불가** — Apple 정책상 CLI로 설치 못 함. Mac App Store에서 "Xcode" 검색 후 한 번만 설치 (대용량, 30분~1시간 소요). 설치 후 위 명령 실행.

### Path C — git clone 후 직접 수동 (개발자용)

```bash
git clone https://github.com/Two-Weeks-Team/ClaudeSync.git
cd ClaudeSync
bash scripts/install.sh
```

`install.sh`는 기본 non-interactive (자동 yes). prompt 모드 원하면 `CLAUDESYNC_INTERACTIVE=1`.

### 세 가지 path 비교

| Path | 사용자 입력 | Xcode 필요? | LLM 필요? | 소요 시간 |
|------|-----------|-----------|---------|----------|
| **B (curl 한 줄, DMG)** ⭐ | curl ... 한 줄 | ❌ 없어도 됨 | ❌ | ~30초 |
| A (AI 위임, source) | "이 프로젝트 설치해서 실행해줘" 한 마디 | ✅ (LLM이 빌드) | ✅ Claude Code | ~2분 |
| C (수동, source) | git clone + cd + bash | ✅ | ❌ | ~2분 |

> 💡 **추천 순서**: 일반 사용자는 B (Xcode 안 받아도 됨). 코드를 살펴보거나 수정하려는 개발자는 A 또는 C.

---

## 전체 흐름 — 두 Mac 처음부터 끝까지

### Step 0 — 사전 점검 (양쪽 Mac 모두)

| 조건 | 어떻게 확인 |
|------|------------|
| macOS 15 (Sequoia) 이상 | 사과 메뉴 → 이 Mac에 관하여 |
| 같은 Wi-Fi / 같은 LAN | 양쪽 Mac의 Wi-Fi 이름 일치 확인 |
| Xcode 설치됨 | Mac App Store → "Xcode" 검색 |

### Step 1 — 설치 (양쪽 Mac에서 따로따로, 동시 가능)

양쪽 Mac에서 각각 터미널 열고:

```bash
curl -fsSL https://raw.githubusercontent.com/Two-Weeks-Team/ClaudeSync/main/scripts/web-install.sh | bash
```

빌드 + 설치 + launch까지 **총 1~2분**. 양쪽이 동시에 실행되어도 무방.

설치 완료 후 양쪽 Mac의 화면 우측 상단 메뉴바에 안테나 아이콘이 등장합니다.

```
[화면 우측 상단 메뉴바]
                                      ┌─ 안테나 아이콘 (ClaudeSync)
                                      │
…  🌐  ⚛  ☁  🍴  🔵  💬  🖥  🕐  🌙  📡  ───→ 클릭
```

### Step 2 — 첫 launch 시 macOS prompt (양쪽 Mac)

처음 launch하면 macOS가 다음을 묻습니다 — **모두 "허용" 클릭**:

| Prompt | 답 |
|--------|-----|
| "ClaudeSync을(를) 여시겠습니까?" (첫 launch만) | **열기** |
| "ClaudeSync이(가) 로컬 네트워크에 있는 디바이스를 찾고 연결하려고 합니다." | **허용** |

### Step 3 — Onboarding 마법사 (양쪽 Mac에서 한 번씩)

메뉴바 안테나 아이콘 클릭 → popover 등장 → **하단 "Onboarding" 버튼** 클릭 → 별도 윈도우 열림.

윈도우에는 6단계가 순서대로:

```
┌──────────────────────────────────────┐
│ Welcome to ClaudeSync                │ ← 현재 step 표시
├──────────────────────────────────────┤
│ Step 1 of 3 — Remote Login           │
│                                      │
│ ⚠ Remote Login is OFF               │
│ [Open System Settings] [Check now]   │
│                              [Continue]
└──────────────────────────────────────┘
```

| Step | 무엇 | 사용자 액션 |
|------|------|-----------|
| ① Welcome | 환영 화면 | "Continue" 클릭 |
| ② Remote Login | sshd 활성 검사 | "Open System Settings" → 시스템 설정에서 **"원격 로그인" 토글 ON** → 윈도우로 돌아와 "Check now" → 녹색 ✓ → "Continue" |
| ③ Full Disk Access | FDA 검사 | "Open System Settings" → 잠금 해제 → **"+" 버튼 → /Applications/ClaudeSync.app 선택** → "Continue" |
| ④ Discovery | 다른 Mac 발견 대기 | 다른 Mac이 같은 단계 도달하면 목록에 자동 등장 → 옆의 **"Pair" 클릭** |
| ⑤ Pairing Code | 6자리 코드 표시 | 다른 Mac 화면의 코드와 **시각적 일치 확인** |
| ⑥ Confirm | 최종 확인 | **"Confirm — codes match" 클릭** → 자동으로 SSH 키 + TLS 핸드셰이크 + 동기화 시작 |

### Step 4 — 페어링 (한 쪽이 Pair 클릭하면 다른 쪽에 배너 등장)

Mac A의 사용자가 ④에서 "Pair" 클릭하면, **Mac B의 메뉴바 popover**에 자동으로 배너가 등장:

```
┌───────────────────────────────────────┐
│ 🔵 ClaudeSync   Searching for peer…  │
├───────────────────────────────────────┤
│ Pair request from MacA               │
│                                       │
│         284579                        │ ← 6자리 코드 (양쪽 동일해야 함)
│                                       │
│ [Accept — codes match]   [Cancel]    │
└───────────────────────────────────────┘
```

**Mac B 사용자**: 코드가 Mac A 화면과 일치하면 "Accept — codes match" 클릭 → Mac A의 Onboarding이 자동으로 Step ⑥로 넘어감 → Mac A 사용자가 "Confirm — codes match" 클릭 → **양쪽 모두 "Watching" 상태** → 동기화 시작.

페어링은 **한 번만**. 영속화되어 양쪽 Mac을 재시작해도 자동 복원.

---

## 무엇을 하나

| 항목 | 값 |
|------|------|
| 동기화 대상 | `~/.claude/`, `~/Library/Application Support/Claude/`, `~/.codex/`, `~/Documents/GitHub/` |
| 발견 | Bonjour `_claudesync._tcp` (같은 LAN) |
| 페어링 | 6자리 시각 확인 코드 + 16-byte nonce + Ed25519 SSH 키 자동 교환 |
| 전송 | rsync over SSH (openrsync 호환) |
| 보안 | TLS + nonce + known_hosts strict + HMAC-signed prefs (10 layers) |
| 리소스 | Idle 25MB Physical Footprint, 0 leaks |
| 의존성 | macOS 15+ + Xcode 만 — 외부 라이브러리 0, 외부 서비스 0 |

---

## 🧑 For Human — 사용자 가이드

### 권한 부여 — 자세히

#### Remote Login (원격 로그인)

`사과 메뉴 → 시스템 설정 → 일반 → 공유` → 우측에서 **"원격 로그인" 토글 ON**.

해제되어 있으면 페어링 후 rsync가 "Connection refused (port 22)"로 실패합니다.

#### Full Disk Access (전체 디스크 접근 권한)

`사과 메뉴 → 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한`:

1. 좌하단 자물쇠 클릭 → Touch ID 또는 비밀번호로 잠금 해제
2. **"+" 버튼** → Finder 다이얼로그 열림
3. `/Applications/ClaudeSync.app` 선택 → "열기"
4. 목록에 ClaudeSync 등장하고 **토글이 켜져있는지** 확인

거부하면 `~/Library/Application Support/Claude` 변경을 감시 못 함 → Claude Desktop 세션 동기화 안 됨.

#### Local Network (로컬 네트워크)

첫 launch 시 자동 prompt. 거부했으면:

`사과 메뉴 → 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크` → ClaudeSync 토글 ON.

### 메뉴바 popover 구조

```
┌─────────────────────────────────────────────┐
│ 🔵 ClaudeSync                               │
│    Watching for changes                    │ ← 현재 상태
├─────────────────────────────────────────────┤
│ Coordinator                                 │
│ Watching for changes                        │
├─────────────────────────────────────────────┤
│ [pairing banner — 페어링 진행 중일 때만 표시]│
├─────────────────────────────────────────────┤
│ Peers on this network                       │
│ • MacBookAir (kim)            [Paired ✓]   │
├─────────────────────────────────────────────┤
│ Targets                                     │
│ 📁 Claude Code         3분 전     [⟳]       │
│ 📁 Claude Desktop      방금       [⟳]       │
│ 📁 Codex CLI           1시간 전   [⟳]       │
│ 📁 Projects            —          [⟳]       │
├─────────────────────────────────────────────┤
│ Recent Activity                             │
│ ✓ Synced successfully                      │
│ ✓ Synced successfully                      │
├─────────────────────────────────────────────┤
│ [Onboarding] [Settings…]            [Quit]  │
└─────────────────────────────────────────────┘
```

### 트러블슈팅

| 증상 | 어디서 보이나 | 해결 |
|------|--------------|------|
| 메뉴바 안테나 아이콘이 없음 | 메뉴바 우상단 | LSUIElement 앱이라 Dock 없음. 다른 메뉴바 아이콘에 가려졌으면 ⌘드래그로 위치 조정 |
| "Searching for peer..." 무한 | 메뉴바 popover 상단 | (1) 양쪽 Mac이 같은 Wi-Fi인지 확인 (2) 회사/카페 Wi-Fi는 mDNS 차단 가능 (3) 양쪽 Mac이 메뉴바에 등장한 상태인지 확인 |
| "Failed: rsync exit=255" | 메뉴바 popover의 Recent Activity | 양쪽 Mac에서 시스템 설정 → 일반 → 공유 → "원격 로그인" ON 확인 |
| "Failed: peer clock skew Ns" | Onboarding 윈도우 또는 메뉴바 banner | 두 Mac의 시각 차이 30초 초과. **양쪽 Mac**에서 시스템 설정 → 일반 → 날짜 및 시간 → "자동으로 시간 설정" 켜기 |
| "another instance is already running" | 터미널 (install.sh 재실행 시) | `killall ClaudeSync` 후 `bash scripts/install.sh` 다시 |
| "Control channel is plaintext" 주황 banner | 메뉴바 popover 상단 | openssl 누락. `brew install openssl` 후 ClaudeSync 재시작 (없어도 페어링/동기화는 정상 동작) |
| 동기화가 너무 자주 일어남 | Recent Activity가 5분 내 50+ 행 | Settings (⌘,) → Excludes 탭에서 자주 변경되는 파일 패턴 추가 |
| Onboarding 윈도우 사라짐 | 메뉴바 popover에서 다시 "Onboarding" 클릭 |  |
| 페어링 후 다른 Mac이 안 보임 | Settings → "Forget paired peer" 클릭 → 처음부터 다시 |  |

### 완전 제거

```bash
killall ClaudeSync                                                # 1) 앱 종료
rm -rf /Applications/ClaudeSync.app ~/.claudesync                 # 2) 앱 + 데이터 제거
sed -i '' '/claudesync@/d' ~/.ssh/authorized_keys                 # 3) (선택) authorized_keys 정리
# 양쪽 Mac에서 같이 진행
```

### 안 함 / 안 됨

- ❌ 3대 이상 Mac (1:1만)
- ❌ 클라우드 경유 (LAN 직결만)
- ❌ iCloud Drive · Dropbox 대체 (AI 도구 환경 전용)
- ❌ Windows / Linux

---

## 🤖 For LLM — Claude Code 등 AI 도구로 작업할 때

### 5초 컨텍스트

```
프로젝트: macOS 메뉴바 트레이 앱 (Swift 6, SwiftUI MenuBarExtra)
목적:    두 Mac 간 Claude/Codex 설정·세션·메모리 동기화
전송:    rsync over SSH + Bonjour 발견 + Ed25519 키 페어링 + TLS
정책:    외부 의존성 0, sandbox 없음, macOS 15+ 전용
상태:    v1.1.0 (코드는 v1.1.1 패치 포함), 214/214 tests green
다음:    Developer ID 서명 + 두 Mac 실기 검증 (사용자 자격증명 필수)
```

### 반드시 먼저 읽을 파일 (이 순서)

1. **`HANDOFF.md`** — 가장 최신 상태, 어디서 이어야 할지
2. **`CLAUDE.md`** — 프로젝트 규칙 (Tech stack, branch 정책, openrsync 호환 flag)
3. **`docs/reports/2026-05-05-v1.1.0-defense-in-depth.html`** — 가장 최근 마일스톤
4. **`docs/prd/PRD.md`** — 무엇을 만드는가
5. **`docs/specs/TECHNICAL_SPEC.md`** — 어떻게 (5269 lines, 필요 시 grep)

### 핵심 명령

```bash
# 빌드 확인
xcodegen generate                                                              # project.yml -> .xcodeproj
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' build

# 테스트 (전체 ~12초, 214/214 통과해야 함)
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test

# Release + Universal binary + DMG
bash scripts/release-build.sh                  # -> .build/release-DD/.../ClaudeSync.app
bash scripts/measure-footprint.sh "<app>"      # -> Physical Footprint vs PRD G4 50MB
bash scripts/package.sh                         # -> dist/ClaudeSync-1.1.0.dmg

# One-shot install (사용자가 두 Mac 각각에서 실행)
bash scripts/install.sh

# 서명·공증 (사용자 자격증명 필요 — LLM이 직접 못 함)
export CODESIGN_IDENTITY="Developer ID Application: ..."
export NOTARY_PROFILE=ClaudeSync
bash scripts/package.sh
```

### 코드베이스 지도

```
ClaudeSync/
├── App/                — @main + @Observable AppEnvironment (DI 컨테이너)
├── Coordinator/        — 3-pump 라우터 (watcher / batch / results)
├── Discovery/          — Bonjour (NWBrowser/NWListener) + ControlMessage + TLS
├── FileWatcher/        — FSEvents -> 2s debounce -> 3-Tier 라우터
├── Pairing/            — 6자리 코드 + nonce + clock skew + 단일 시도
│   └── Preflight/     — Remote Login / FDA / SSH connectivity
├── Persistence/        — preferences.json (HMAC) + history.json + paired peer
├── SSH/                — Ed25519 키 + authorized_keys + known_hosts + wrapper
├── Sync/               — rsync builder + queue + ConflictResolver (newer-wins)
├── UI/                 — MenuBarRootView + Settings + Onboarding
├── Utilities/          — ProcessRunner + Logger + LaunchAtLogin
│                          + NetworkResilience + SingleInstanceGuard
└── Resources/          — Info.plist + entitlements + AppIcon

ClaudeSyncTests/        — 26 스위트 / 214 테스트
scripts/                — install / web-install / release-build / measure-footprint / package
docs/
├── prd/                — PRD
├── specs/              — Technical spec, Test strategy
├── references/         — Tech references
├── reports/            — Phase 1~6 + v1.0/v1.0.1/v1.1.0 milestones (HTML)
├── screenshots/        — 메뉴바 / 사용자 가이드용 캡처
└── DEMO_TWO_MACS.md    — 두 Mac 실기 시연 가이드
```

### 위반 금지 (CLAUDE.md 발췌)

- ❌ 외부 라이브러리 추가 금지 (SPM dependency 0 정책)
- ❌ Sandbox 켜기 금지 (rsync/ssh-keygen/openssl 실행 못 함)
- ❌ GNU rsync 전용 flag 사용 금지 (openrsync 호환만: `--archive --compress --delete --update --itemize-changes --partial --timeout=30`)
- ❌ Squash merge 금지 (`gh pr merge --merge`)
- ❌ 사용자에게 텍스트로 묻지 마라 — `AskUserQuestion` 도구만
- ❌ 보고를 텍스트만으로 끝내지 마라 — HTML 보고서 (`docs/reports/`) 생성

### 자주 막히는 부분

| 막힘 | 해결 |
|------|------|
| "matching destinations" warning | 무해. 무시 |
| Swift 6 actor 격리 에러 | `nonisolated` 또는 `@MainActor` 명시 |
| Settings 변경이 sync에 반영 안 됨 | `AppEnvironment.applyPreferences()`가 builder를 swap해야 함 |
| 새 Swift 파일이 컴파일 안 됨 | `xcodegen generate` 다시 |
| `setenv("HOME")` 테스트 race | parallelTesting 비활성화 또는 `homeDirectory` 주입 |
| TLS handshake 실패 | `~/.claudesync/tls/server.p12` 권한 0o600 + openssl 경로 확인 (없으면 plaintext fallback 동작) |
| `xcodebuild test`가 즉시 exit | SingleInstanceGuard가 다른 ClaudeSync.app 발견 — XCTest 환경변수 감지로 자동 skip되지만, 안 되면 `CLAUDESYNC_DISABLE_SINGLE_INSTANCE=1` |

### 다음 LLM 세션 Resume Prompt

`HANDOFF.md`의 "Resume Prompt" 섹션이 항상 최신. v1.1.0 기준:

> 이전 세션에서 ClaudeSync v1.1.0까지 완료했습니다 (TLS, nonce, known_hosts, HMAC, auto recovery, single-instance, install.sh, web-install.sh). HANDOFF.md를 읽고 현재 상태를 파악한 후, 서명+공증 / 두 Mac 실기 검증 / GitHub Release 중 사용자가 원하는 작업을 진행하세요. 테스트 214/214 그린.

---

## 스크린샷 추가 가이드

스크린샷은 사용자가 직접 `docs/screenshots/`에 PNG로 추가하는 것이 가장 정확합니다. 권장 캡처 (Shift+Cmd+4 → 영역 드래그):

| 파일명 | 무엇을 캡처 |
|--------|-----------|
| `docs/screenshots/menubar-tray.png` | 메뉴바 우상단 안테나 아이콘 영역 (이미 자동 캡처됨) |
| `docs/screenshots/menubar-popover.png` | 안테나 클릭 후 나타나는 popover 전체 |
| `docs/screenshots/onboarding-step1.png` | Onboarding의 Remote Login 단계 |
| `docs/screenshots/onboarding-pair.png` | Onboarding의 6자리 코드 표시 화면 |
| `docs/screenshots/menubar-pair-banner.png` | 메뉴바의 Pair request 배너 |

추가 후 README의 해당 섹션에 `![](docs/screenshots/파일명.png)` 추가.

---

## License

내부 프로젝트.

## Repository

- GitHub: https://github.com/Two-Weeks-Team/ClaudeSync
- 마일스톤별 결정 과정과 패치 이유: `docs/reports/`의 HTML 보고서들

## Credits

이 프로젝트는 Claude Code (Anthropic Opus 4.7)와 페어 코딩으로 작성되었습니다.
