# ClaudeSync

> macOS 메뉴바 앱. 두 Mac 간 Claude Code · Claude Desktop · Codex CLI의 설정 / 세션 / 메모리를 자동 동기화합니다.

[![tests](https://img.shields.io/badge/tests-214%20passing-3fb950)]() [![macOS](https://img.shields.io/badge/macOS-15%2B-58a6ff)]() [![arch](https://img.shields.io/badge/arch-arm64%20%2B%20x86__64-d2a8ff)]() [![version](https://img.shields.io/badge/version-1.1.0-d29922)]()

---

## 30초 설치

**두 Mac 각각에서 똑같이 한 번씩**:

```bash
git clone https://github.com/Two-Weeks-Team/ClaudeSync.git
cd ClaudeSync
bash scripts/install.sh
```

이게 전부입니다. `install.sh`가:

1. macOS 15+ / Xcode / xcodegen 사전점검
2. Universal Release 빌드 (arm64 + x86_64)
3. `/Applications/ClaudeSync.app` 설치 + Gatekeeper quarantine 플래그 제거
4. 앱 실행 → 메뉴바 트레이 등장 + Bonjour 광고 확인

다음에 메뉴바 안테나 아이콘을 클릭해 페어링 흐름 진행 → 끝.

> 💡 두 번째 Mac에서도 똑같이 위 3줄. 양쪽 모두 launch되면 자동으로 서로 발견하고 페어링 UI를 띄웁니다.

---

## 무엇을 하나

| 항목 | 값 |
|------|------|
| 동기화 대상 | `~/.claude/`, `~/Library/Application Support/Claude/`, `~/.codex/`, `~/Documents/GitHub/` |
| 발견 | Bonjour `_claudesync._tcp` (같은 LAN) |
| 페어링 | 6자리 시각 확인 코드 + Ed25519 SSH 키 자동 교환 + nonce |
| 전송 | rsync over SSH (openrsync 호환) |
| 보안 | TLS + nonce + known_hosts strict + HMAC-signed prefs (10 layers) |
| 리소스 | Idle 25MB Physical Footprint, 0 leaks |
| 의존성 | macOS 15+ + Xcode 만 — 외부 라이브러리 0, 외부 서비스 0 |

---

## 🧑 For Human — 사용자 가이드

### 사전 요구

- **macOS Sequoia (15) 이상** Mac 두 대
- 두 Mac이 **같은 Wi-Fi / 같은 LAN**
- **Xcode** (Mac App Store에서 설치) — `install.sh`가 빌드 시 사용
- (자동) **xcodegen** — `install.sh`가 Homebrew로 설치 안내

### 페어링 흐름 (양쪽 install 완료 후)

**Mac A에서**:
1. 메뉴바의 안테나 아이콘 클릭 → popover 열림
2. "Onboarding" 클릭 → 3단계 사전점검 (Remote Login / FDA / 로컬 네트워크)
3. Discovery step에서 Mac B가 목록에 나타나면 → "Pair" 클릭
4. 6자리 코드 표시

**Mac B에서**:
5. 메뉴바 popover에 "Pair request from MacA" 배너 자동 등장
6. 코드가 Mac A 화면과 일치하는지 시각으로 확인
7. "Accept — codes match" 클릭

**Mac A에서**:
8. "Confirm — codes match" 클릭
9. 자동으로 SSH 키 교환 + TLS 핸드셰이크 + known_hosts 등록 완료
10. "Watching" 상태 — 동기화 시작 🎉

페어링은 **한 번만**. 영속화되어 재시작해도 자동 복원됩니다.

### 권한

`install.sh` 실행 후 첫 launch 시 macOS가 묻는 권한들:

| 권한 | 어디서 | 왜 |
|------|------|-----|
| **로컬 네트워크** | 첫 실행 시 자동 prompt — 허용 | Bonjour 발견 |
| **Remote Login (SSH)** | 시스템 설정 → 일반 → 공유 → "원격 로그인" | rsync over SSH |
| **Full Disk Access** | 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한 → ClaudeSync 추가 | `~/Library/Application Support/Claude` 감시 |

Onboarding 윈도우가 각 단계에서 자동으로 안내합니다.

### 트러블슈팅

| 증상 | 해결 |
|------|------|
| 메뉴바 아이콘이 안 보임 | LSUIElement 앱이라 Dock 없음. 메뉴바 우상단 영역 확인 |
| "Searching for peer..." 영원 | 같은 Wi-Fi인지 확인. 회사/카페 Wi-Fi는 mDNS 차단 가능 |
| Pair 했는데 "Failed: rsync exit=255" | Remote Login이 양쪽 Mac에서 켜져있는지 확인 |
| "Failed: peer clock skew Ns" | 두 Mac 시각 차이 30초 초과. 시스템 설정 → 일반 → 날짜 및 시간 → "자동" |
| "another instance is already running" | 이미 같은 Mac에서 실행 중. Activity Monitor에서 확인 |
| 동기화가 너무 자주 일어남 | Settings (⌘,) → Excludes에서 임시 파일 패턴 추가 |

### 완전 제거

```bash
pkill -x ClaudeSync
rm -rf /Applications/ClaudeSync.app ~/.claudesync
# (선택) authorized_keys에서 claudesync@ 라인도 제거
sed -i '' '/claudesync@/d' ~/.ssh/authorized_keys
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
상태:    v1.1.0, 214/214 tests green
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
xcodegen generate                                                              # project.yml → .xcodeproj
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' build

# 테스트 (전체 ~12초, 214/214 통과해야 함)
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test

# Release + Universal binary + DMG
bash scripts/release-build.sh                  # → .build/release-DD/.../ClaudeSync.app
bash scripts/measure-footprint.sh "<app>"      # → Physical Footprint vs PRD G4 50MB
bash scripts/package.sh                         # → dist/ClaudeSync-1.1.0.dmg

# One-shot install (사용자가 두 Mac 각각에서 실행)
bash scripts/install.sh

# 서명·공증 (사용자 자격증명 필요)
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
├── FileWatcher/        — FSEvents → 2s debounce → 3-Tier 라우터
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
scripts/                — install / release-build / measure-footprint / package
docs/
├── prd/                — PRD
├── specs/              — Technical spec, Test strategy
├── references/         — Tech references
├── reports/            — Phase 1~6 + v1.0/v1.0.1/v1.1.0 milestones (HTML)
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

### 다음 LLM 세션 Resume Prompt

`HANDOFF.md`의 "Resume Prompt" 섹션이 항상 최신. v1.1.0 기준:

> 이전 세션에서 ClaudeSync v1.1.0까지 완료했습니다 (TLS, nonce, known_hosts, HMAC, auto recovery, single-instance, install.sh). HANDOFF.md를 읽고 현재 상태를 파악한 후, 서명+공증 / 두 Mac 실기 검증 / GitHub Release 중 사용자가 원하는 작업을 진행하세요. 테스트 214/214 그린.

---

## License

내부 프로젝트.

## Repository

- GitHub: https://github.com/Two-Weeks-Team/ClaudeSync
- 마일스톤별 결정 과정과 패치 이유: `docs/reports/`의 HTML 보고서들

## Credits

이 프로젝트는 Claude Code (Anthropic Opus 4.7)와 페어 코딩으로 작성되었습니다.
