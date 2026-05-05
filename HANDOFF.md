# ClaudeSync — Handoff Document

## Project Status: Phase 1 (Xcode 스켈레톤) 완료, Phase 2 진입 대기

### Phase 1 완료 내역 (2026-05-05)

| 산출물 | 경로 |
|--------|------|
| xcodegen 매니페스트 | `project.yml` |
| Xcode 프로젝트 | `ClaudeSync.xcodeproj/` |
| @main + MenuBarExtra(.window) | `ClaudeSync/App/ClaudeSyncApp.swift` |
| @Observable DI 컨테이너 | `ClaudeSync/App/AppEnvironment.swift` |
| 메뉴바 popover (320pt) | `ClaudeSync/UI/MenuBarRootView.swift` |
| async Process wrapper | `ClaudeSync/Utilities/ProcessRunner.swift` |
| os.Logger + 10MB 롤링 파일 | `ClaudeSync/Utilities/Logger.swift` |
| Info.plist (LSUIElement, NSBonjourServices) | `ClaudeSync/Resources/Info.plist` |
| 엔타이틀먼트 (no sandbox, network) | `ClaudeSync/Resources/ClaudeSync.entitlements` |
| 4개 스모크 테스트 | `ClaudeSyncTests/SmokeTests.swift` |

**검증 결과**: clean build OK, 4/4 unit tests pass, 앱 실행 후 t=5s 생존(메뉴바 영속), SIGTERM 정상 종료, ~/.claudesync/logs/claudesync.log 자동 생성.

**Phase 4 hardening 후속과제 (Phase 1 비차단)**:
- RSS 77.5MB (PRD G4 <50MB 목표 초과 — Debug 빌드 unwarmed; Release 측정 필요)
- Assets.car 미생성 (AppIcon/AccentColor 비어있음 — 메뉴바는 SF Symbol 사용 중이라 무영향)
- Universal binary 미설정 (현재 arm64만; ARCHS=arm64 x86_64 Phase 4에서 추가)
- Adhoc 서명 (Developer ID 서명/공증은 Phase 4)

---

## Original Status (Phase 0 종료): PRD + Specs 완료, Momus 검증 수정 진행중

### Quick Start
```bash
cd /Users/kimsejun/Documents/GitHub/ClaudeSync
claude
```

---

## What Is ClaudeSync?

macOS 메뉴바 트레이 앱. 두 대의 Mac에서 AI 코딩 도구 환경(Claude Code, Codex CLI)을 **자동으로 완전히 동기화**합니다.

- 같은 WiFi → Bonjour 자동 발견
- FSEvents → 파일 변경 감지 → rsync over SSH 즉시 동기화
- 설정, 스킬, 훅, 메모리, 세션, 트랜스크립트, 프로젝트 폴더 전부

---

## Repository

- **GitHub**: https://github.com/Two-Weeks-Team/ClaudeSync
- **Local**: /Users/kimsejun/Documents/GitHub/ClaudeSync

---

## Completed Documents

| Document | Path | Size | Status |
|----------|------|------|--------|
| **PRD** | `docs/prd/PRD.md` | 31KB | ✅ Complete (Momus 수정 반영중) |
| **Technical Spec** | `docs/specs/TECHNICAL_SPEC.md` | 79KB | ✅ Complete (Momus 수정 반영중) |
| **Tech References** | `docs/references/TECH_REFERENCES.md` | 55KB | ✅ Complete |
| **Test Strategy** | `docs/specs/TEST_STRATEGY.md` | — | 🔄 생성중 (Momus R3) |
| **README** | `README.md` | 1KB | ✅ Complete |

---

## Momus Validation Result: NEEDS_REVISION (0.67/0.70)

### Critical Fixes (반영중)

| # | Issue | Fix |
|---|-------|-----|
| R1 | Sync loop prevention | rsync PID 기반 per-file suppression으로 변경 |
| R2 | Remote Login 미언급 | 사전조건 + preflight SSH 체크 추가 |
| R3 | 테스트 전략 부재 | TEST_STRATEGY.md 생성 |
| R4 | 3-Tier 동기화 | 실시간/배치/온디맨드 분리 |
| R5 | 페어링 코드 보안 | SHA-256(pubkey_A || pubkey_B) 방식 |
| R6 | Full Disk Access | 첫 실행 시 권한 요청 플로우 추가 |
| R7 | openrsync 호환성 | 안전 플래그셋 사용, Homebrew rsync 옵션 |

---

## Architecture Overview

```
┌──────────────┐     Bonjour (_claudesync._tcp)     ┌──────────────┐
│  MacBook Pro │  ◄──────── 자동 발견 ────────►  │  MacBook Air │
│  트레이 🟢   │     rsync over SSH (delta)       │  트레이 🟢   │
│              │  ◄──────── 실시간 동기화 ──────►  │              │
└──────────────┘     FSEvents → 변경감지 → 즉시    └──────────────┘
```

### 3-Tier Sync (Momus R4 반영)

| Tier | Target | Debounce | Latency |
|------|--------|----------|---------|
| **1 Real-time** | settings, CLAUDE.md, hooks, commands, memory | 2s | <3s |
| **2 Batched** | sessions, transcripts (2.2GB) | 5min | <6min |
| **3 On-demand** | ~/Documents/GitHub (67GB), brew, npm | Manual/Scheduled | varies |

### Tech Stack
- Swift 6.2, SwiftUI MenuBarExtra (.window)
- Network.framework (NWBrowser/NWListener)
- FSEvents (C API → AsyncStream bridge)
- Foundation.Process (rsync, ssh-keygen)
- macOS 15+ (Sequoia/Tahoe)
- No sandbox, no external dependencies

---

## File Structure (Target)

```
ClaudeSync/
├── ClaudeSync/
│   ├── App/                    ← @main, MenuBarExtra
│   ├── Coordinator/            ← SyncCoordinator (@MainActor)
│   ├── Discovery/              ← Bonjour (NWBrowser/NWListener)
│   ├── Sync/                   ← rsync engine, conflicts
│   ├── FileWatcher/            ← FSEvents
│   ├── PackageSync/            ← brew/npm sync
│   ├── SSH/                    ← Ed25519 key management
│   ├── UI/                     ← SwiftUI views
│   ├── Persistence/            ← UserDefaults, history
│   └── Utilities/              ← ProcessRunner, Logger, Debouncer
├── ClaudeSyncTests/
├── docs/
│   ├── prd/PRD.md              ← Product Requirements
│   ├── specs/TECHNICAL_SPEC.md ← Detailed Technical Spec
│   ├── specs/TEST_STRATEGY.md  ← Test Plan
│   └── references/TECH_REFERENCES.md ← API/Framework docs
├── README.md
├── LICENSE (MIT)
└── .gitignore
```

---

## Next Steps (Implementation Order)

### Phase 1: Xcode Project Skeleton (Day 1)
- [ ] Xcode project 생성 (macOS App, Swift 6, no storyboard)
- [ ] Info.plist: LSUIElement=YES, NSBonjourServices
- [ ] ClaudeSyncApp.swift with MenuBarExtra
- [ ] ProcessRunner.swift + Logger.swift
- [ ] 메뉴바 아이콘 표시 확인

### Phase 2: SSH + Pairing (Day 2)
- [ ] SSHKeyManager — Ed25519 키 생성
- [ ] PairingManager — 상태 머신
- [ ] Remote Login preflight 체크
- [ ] FirstLaunchPairingView

### Phase 3: Bonjour Discovery (Day 3)
- [ ] PeerDiscoveryActor — NWBrowser + NWListener
- [ ] NWProtocolFramer — length-prefixed JSON
- [ ] Heartbeat 프로토콜
- [ ] PeerInfo → SyncCoordinator 연결

### Phase 4: File Watching (Day 4)
- [ ] FileWatcherActor — FSEvents C API
- [ ] Debouncer — 2s per-path quiet period
- [ ] 3-Tier 대상별 watch 등록

### Phase 5: Sync Engine (Day 5-6)
- [ ] FileSyncActor — rsync job queue
- [ ] SyncTarget enum — 6개 대상
- [ ] ConflictResolver
- [ ] Sync loop prevention (PID-based)

### Phase 6: Package Sync + UI (Day 7-8)
- [ ] BrewSyncManager, NpmGlobalSyncManager
- [ ] MenuBarView (전체 UI)
- [ ] EnvironmentDiffView
- [ ] SyncHistory

---

## Key Technical Decisions

1. **openrsync 호환**: macOS 내장 rsync는 openrsync로 교체됨. `--log-file`, `-E`, `--backup-dir` 사용 불가. 안전 플래그셋만 사용.
2. **No Sandbox**: rsync, ssh-keygen, ~/.ssh/ 접근 필요. Mac App Store 배포 불가, Developer ID 직접 서명.
3. **SSH 키 분리**: `~/.claudesync/ssh/id_claudesync_ed25519` — 사용자 SSH 키와 분리.
4. **Swift 6.2 Concurrency**: `@MainActor` UI + Domain actors + AsyncStream 패턴.

---

## Environment Info (Both Machines)

| | MacBook Pro | MacBook Air |
|---|---|---|
| Username | kimsejun | kimsejun |
| Home | /Users/kimsejun | /Users/kimsejun |
| macOS | 26.3 | — |
| Claude Code | 2.1.126 | 2.1.128 |
| ~/.claude/ | 3.0GB | 726MB |
| GitHub/ | 67GB | 15GB |
| Hostname | KimSejunui-MacBookPro | KimSejunui-MacBookAir |

---

## Resume Prompt

다음 세션에서 이어서 작업할 때:

```
이전 세션에서 ClaudeSync 프로젝트의 PRD, Technical Spec, Tech References, 
Test Strategy 문서를 완성했습니다. Momus 검증에서 NEEDS_REVISION을 받아 
7가지 수정사항(sync loop, Remote Login, 3-tier sync, 페어링 보안, FDA, 
debounce, openrsync)을 반영했습니다.

HANDOFF.md를 읽고, Phase 1(Xcode 프로젝트 생성)부터 구현을 시작하세요.
```
