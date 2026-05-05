# ClaudeSync — Handoff Document

## Project Status: v0.3 도달 — 자동 페어링 완성, 출하 hardening 대기

### 마지막 세션 (2026-05-05) 성과 요약

| 지표 | 값 |
|------|------|
| 완료된 Phase | **1, 2, 3, 4, 5, 6** + v0.2 wiring + v0.3 자동 페어링 |
| 커밋 (origin/main 동기화) | **14개** |
| 신규 Source 파일 | ~40개 |
| 테스트 스위트 / 테스트 | 22 / **162 PASS** |
| 총 라인 수 (코드+테스트) | ~6,800 |
| HTML 보고서 | 5개 (`docs/reports/`) |
| 마일스톤 | **v0.1.0 MVP → v0.2 wiring → v0.3 auto-pairing** |

### v0.3에서 동작하는 기능

1. **앱 부팅 → 메뉴바 트레이 자동 등장** (LSUIElement, no Dock icon)
2. **자동 부팅 시점에 Bonjour `_claudesync._tcp` 광고 + 브라우징** (dns-sd로 검증됨)
3. **FSEvents 파일 감시 4개 타겟** (~/.claude, ~/Library/Application Support/Claude, ~/.codex; ~/Documents/GitHub은 onDemand)
4. **2초 per-path debouncer + 3-Tier 라우터** → SyncCoordinator → FileSyncActor 큐
5. **rsync 명령 빌더** (openrsync 호환 + Homebrew 자동 검출)
6. **메뉴바 popover** — coordinator 상태, 발견된 peer + Pair 버튼, target별 last-sync + force-sync, 최근 활동 5개
7. **Onboarding 윈도우** — Welcome → Remote Login preflight → FDA preflight → discovery → 6자리 코드 + accept/confirm/reject
8. **자동 페어링** — 메뉴바 "Pair" 버튼 → NWConnection → PairingManager → 양측 코드 일치 → authorized_keys 설치 → FileSyncActor.setPeer 자동 wiring
9. **SyncHistory 영속화** (~/.claudesync/history.json, 100건)
10. **ConflictResolver** (newer-wins + JSON merge + tie keepBoth + 30일 archive purge)

### 출하 (v1.0) 잔여 작업

- [ ] **두 Mac 실기 검증** — `docs/DEMO_TWO_MACS.md` 따라 사용자 직접
- [ ] Universal binary (`ARCHS = arm64 x86_64`)
- [ ] AppIcon 자산 작성 (16/32/128/256/512 + @2x)
- [ ] Developer ID Application 서명 + `xcrun notarytool` 공증
- [ ] DMG 패키징 + GitHub Release
- [ ] Launch at Login (`SMAppService.mainApp.register`)
- [ ] Release 빌드 RSS 측정 (PRD G4 50MB 목표 검증)
- [ ] 72시간 dogfood 안정성 테스트
- [ ] (옵션) BrewSyncManager / NpmGlobalSyncManager / EnvironmentDiffView (HANDOFF Phase 6 잔여, v1.1로 미뤄도 무방)
- [ ] (옵션) Settings Window — bandwidth, exclude patterns

---

## Quick Start (다음 세션)

```bash
cd /Users/kimsejun/Documents/GitHub/ClaudeSync
git pull
brew install xcodegen rsync   # 필요 시
xcodegen generate
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test
# → 162/162 PASS

# 앱 실행
xcodebuild -scheme ClaudeSync -configuration Debug build
APP=$(xcodebuild -scheme ClaudeSync -showBuildSettings 2>/dev/null | grep BUILT_PRODUCTS_DIR | awk -F= '{print $2}' | xargs)
"$APP/ClaudeSync.app/Contents/MacOS/ClaudeSync" &
```

---

## Repository

- **GitHub**: https://github.com/Two-Weeks-Team/ClaudeSync
- **Local**: /Users/kimsejun/Documents/GitHub/ClaudeSync
- **Branch**: main (origin/main 동기화)

---

## 핵심 문서

| 문서 | 경로 |
|------|------|
| PRD | `docs/prd/PRD.md` |
| Technical Spec | `docs/specs/TECHNICAL_SPEC.md` (5269 lines) |
| Test Strategy | `docs/specs/TEST_STRATEGY.md` |
| Tech References | `docs/references/TECH_REFERENCES.md` |
| **두 Mac 실기 시연 가이드** | `docs/DEMO_TWO_MACS.md` |
| Phase 1 보고서 | `docs/reports/phase1-completion.html` |
| Phase 2+3 보고서 | `docs/reports/2026-05-05-phase2-3-completion.html` |
| Phase 4 보고서 | `docs/reports/2026-05-05-phase4-completion.html` |
| Phase 5 보고서 | `docs/reports/2026-05-05-phase5-completion.html` |
| Phase 6 보고서 | `docs/reports/2026-05-05-phase6-completion.html` |

---

## 현재 코드베이스 구조

```
ClaudeSync/
├── App/
│   ├── ClaudeSyncApp.swift           — @main + MenuBarExtra + WindowGroup("onboarding")
│   └── AppEnvironment.swift          — @Observable DI 컨테이너, 모든 액터 + 자동 페어링 wiring
├── Coordinator/
│   └── SyncCoordinator.swift         — 3개 pump (watcher/batch/results)
├── Discovery/
│   ├── ControlMessage.swift          — pairRequest/Accept/Confirm/Reject + heartbeat 등
│   ├── FrameCodec.swift              — 4-byte BE 길이접두 codec + StreamReader
│   ├── ClaudeSyncProtocolFramer.swift — NWProtocolFramer Network.framework 어댑터
│   ├── PeerChannel.swift             — 프로토콜 + LoopbackPeerChannel (테스트)
│   ├── NWConnectionPeerChannel.swift — production NWConnection wrapper
│   ├── PeerInfo.swift                — Bonjour TXT 디코딩
│   └── PeerDiscoveryActor.swift      — NWBrowser/NWListener actor
├── FileWatcher/
│   ├── Debouncer.swift               — per-path 2s quiet-period
│   ├── FSEventStreamWatcher.swift    — FSEvents C API 브리지
│   └── FileWatcherActor.swift        — 4개 타겟 + 3-Tier 라우터
├── Pairing/
│   ├── PairingCodeGenerator.swift    — SHA-256 6자리 코드 (security-critical)
│   ├── PairingManager.swift          — 대칭 페어링 상태머신
│   └── Preflight/
│       ├── SSHConnectivityChecker.swift   — 프로토콜 + Process/Mock
│       ├── RemoteLoginPreflight.swift     — sshd 검사
│       ├── FullDiskAccessChecker.swift    — ~/Library/Cookies/ canary
│       └── SystemSettingsLink.swift       — x-apple.systempreferences URL
├── Persistence/
│   └── SyncHistory.swift             — ~/.claudesync/history.json (100건)
├── SSH/
│   └── SSHKeyManager.swift           — Ed25519 + authorized_keys 라운드트립
├── Sync/
│   ├── SyncTarget.swift              — 4 case enum + spec + tier 매핑
│   ├── IgnorePatterns.swift          — security/global/perTarget excludes + glob
│   ├── SyncJob.swift                 — SyncJob + SyncResult + PriorityQueue
│   ├── RsyncCommandBuilder.swift     — openrsync 호환 + Homebrew 자동 검출
│   ├── BatchAccumulator.swift        — Tier 2 5분 누적
│   ├── ConflictResolver.swift        — newer-wins + JSON merge + keepBoth
│   └── FileSyncActor.swift           — rsync 큐 + PID 동기화
├── UI/
│   ├── MenuBarRootView.swift         — 메뉴바 popover (peer/target/activity)
│   ├── OnboardingViewModel.swift     — 5스텝 상태머신 + 콜백 hook
│   └── FirstLaunchPairingView.swift  — SwiftUI 5스텝 윈도우
├── Utilities/
│   ├── ProcessRunner.swift           — actor 비동기 Process wrapper
│   └── Logger.swift                  — os.Logger + 10MB 롤링 파일
└── Resources/
    ├── Info.plist
    ├── ClaudeSync.entitlements
    └── Assets.xcassets/              — AppIcon/AccentColor (placeholder, v1.0 hardening 시 채움)

ClaudeSyncTests/                       — 22 스위트 162 테스트
```

---

## 사용자 영구 선호 (메모리에 저장됨)

위치: `/Users/kimsejun/.claude/projects/-Users-kimsejun-Documents-GitHub-ClaudeSync/memory/`

- **모든 보고는 HTML 보고서로** (`/html-report` 사용, 텍스트 마크다운만으로 끝내지 않음)
- **사용자 질문은 항상 AskUserQuestion 도구로** (텍스트로 묻지 않음)

---

## 다음 세션 추천 첫 작업

1. **두 Mac 실기 검증** — `docs/DEMO_TWO_MACS.md` 따라 진행. 발견되는 이슈를 패치.
2. **v1.0 hardening** — Universal binary + Developer ID 서명 + AppIcon + DMG.
3. **(옵션) BrewSyncManager** — Phase 6의 잔여 항목, v1.1 후보.

---

## Resume Prompt (다음 세션용)

```
이전 세션에서 ClaudeSync v0.3 (자동 페어링 완성)까지 완료했습니다.
HANDOFF.md를 읽고 현재 상태를 파악한 후, v1.0 출하 hardening
또는 두 Mac 실기 검증 중 사용자가 원하는 작업을 진행하세요.

테스트는 162/162 그린, main이 origin/main과 동기화 상태입니다.
```
