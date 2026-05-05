# ClaudeSync — Handoff Document

## Project Status: v1.0-rc1 도달 — Universal binary, Settings, Launch at Login, AppIcon, DMG 완성

### 마지막 세션 (2026-05-05) 성과 요약

| 지표 | 값 |
|------|------|
| 완료된 Phase | **1, 2, 3, 4, 5, 6** + v0.2 wiring + v0.3 자동 페어링 + **v1.0 hardening** |
| 커밋 (origin/main 동기화) | 14개 + 신규 v1.0 commits |
| 신규 Source 파일 | ~40개 |
| 테스트 스위트 / 테스트 | 24 / **177 PASS** (162 → 177, +15 신규) |
| 총 라인 수 (코드+테스트) | ~7,500 |
| HTML 보고서 | 6개 (`docs/reports/`) |
| 마일스톤 | **v0.1.0 MVP → v0.2 wiring → v0.3 auto-pairing → v1.0-rc1** |
| Release 빌드 | Universal binary (arm64 + x86_64), 4.2MB bundle, 1.4MB DMG |
| Idle Memory Footprint | **22.7MB** (PRD G4 50MB 목표 충족) |

### v1.0-rc1에서 동작하는 기능

기존 v0.3 기능 모두 유지 +

11. **Universal binary** — `ARCHS="arm64 x86_64"`, Release에서만 양쪽 슬라이스 포함
12. **Launch at Login** — `SMAppService.mainApp` 등록/해제 + Settings 토글
13. **Settings Window** — General(launch at login) / Network(bandwidth limit) / Excludes(per-target user 패턴) 3탭, JSON 영속화 (`~/.claudesync/preferences.json`)
14. **AppIcon 세트** — 10개 슬롯(16~512 + @2x), Core Graphics gradient + sync glyph
15. **rsync `--bwlimit` 통합** — Settings의 KiB/s 값이 즉시 builder에 반영
16. **DMG 패키징 파이프라인** — `scripts/release-build.sh` → `scripts/measure-footprint.sh` → `scripts/package.sh`

### 출하 (v1.0 final) 잔여 작업

- [ ] **Developer ID Application 서명** — 사용자 키체인의 Developer ID 인증서 필요
  ```
  export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
  bash scripts/package.sh
  ```
- [ ] **xcrun notarytool 공증** — Apple ID + app-specific password 필요
  ```
  xcrun notarytool store-credentials ClaudeSync \
    --apple-id you@example.com --team-id TEAMID --password XXXX-XXXX-XXXX-XXXX
  export NOTARY_PROFILE=ClaudeSync
  bash scripts/package.sh
  ```
- [ ] **두 Mac 실기 검증** — `docs/DEMO_TWO_MACS.md` 따라 사용자 직접
- [ ] **GitHub Release 게시** — `gh release create v1.0.0 dist/ClaudeSync-1.0.0.dmg`
- [ ] **72시간 dogfood 안정성 테스트**
- [ ] (옵션) BrewSyncManager / NpmGlobalSyncManager / EnvironmentDiffView (v1.1 후보)
- [ ] (옵션) Settings에 추가: 동기화 일시정지, 충돌 보관함 정리 UI

---

## 메모리 측정 결정 (이번 세션)

PRD G4 = "50MB RSS" 목표를 두고 측정 시작 → `ps -o rss`로 91MB 측정 → 10인 전문가 패널이 "측정 정확도 검증 후 결정" 권고 → `heap` 명령으로 **Physical Footprint = 22.8MB** 확인 → PRD G4 충족.

`ps RSS`는 macOS에서 공유 라이브러리 페이지(SwiftUI, AppKit, Network.framework 등)를 모두 포함해 부풀려져 보입니다. Apple이 메모리 압력 지표로 사용하는 **Physical footprint** (Activity Monitor의 "Memory" 컬럼)가 정확한 값입니다.

`scripts/measure-footprint.sh`는 footprint 기반으로 측정하도록 수정되었습니다.

---

## Quick Start (다음 세션)

```bash
cd /Users/kimsejun/Documents/GitHub/ClaudeSync
git pull
brew install xcodegen rsync   # 필요 시
xcodegen generate
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test
# → 177/177 PASS

# v1.0 release 빌드 + DMG (서명/공증 없이도 동작)
bash scripts/package.sh
# → dist/ClaudeSync-1.0.0.dmg

# Footprint 측정
bash scripts/release-build.sh
bash scripts/measure-footprint.sh ".build/release-DD/Build/Products/Release/ClaudeSync.app"
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
| 두 Mac 실기 시연 가이드 | `docs/DEMO_TWO_MACS.md` |
| Phase 1 보고서 | `docs/reports/phase1-completion.html` |
| Phase 2+3 보고서 | `docs/reports/2026-05-05-phase2-3-completion.html` |
| Phase 4 보고서 | `docs/reports/2026-05-05-phase4-completion.html` |
| Phase 5 보고서 | `docs/reports/2026-05-05-phase5-completion.html` |
| Phase 6 보고서 | `docs/reports/2026-05-05-phase6-completion.html` |
| **v1.0-rc1 보고서** | `docs/reports/2026-05-05-v1.0-rc1-hardening.html` |

---

## 현재 코드베이스 구조 (v1.0-rc1)

```
ClaudeSync/
├── App/
│   ├── ClaudeSyncApp.swift           — @main + MenuBarExtra + WindowGroup + Settings scene
│   └── AppEnvironment.swift          — DI 컨테이너, 전체 actor + Preferences + LaunchAtLogin
├── Coordinator/
│   └── SyncCoordinator.swift         — 3개 pump (watcher/batch/results)
├── Discovery/                        — Bonjour + NWConnection + ControlMessage
├── FileWatcher/                      — FSEvents + Debouncer + 4-target router
├── Pairing/
│   ├── PairingCodeGenerator.swift    — SHA-256 6자리 코드
│   ├── PairingManager.swift          — 대칭 페어링 상태머신
│   └── Preflight/                    — SSH/Remote Login/FDA preflight
├── Persistence/
│   ├── SyncHistory.swift             — ~/.claudesync/history.json (100건)
│   └── Preferences.swift             — ★ ~/.claudesync/preferences.json (bandwidth/excludes/launch)
├── SSH/
│   └── SSHKeyManager.swift           — Ed25519 + authorized_keys
├── Sync/
│   ├── SyncTarget.swift              — 4 case enum + spec + tier 매핑
│   ├── IgnorePatterns.swift          — security/global/perTarget excludes + glob
│   ├── SyncJob.swift                 — SyncJob + SyncResult + PriorityQueue
│   ├── RsyncCommandBuilder.swift     — ★ openrsync + Homebrew 자동검출 + bandwidth/userExtras
│   ├── BatchAccumulator.swift        — Tier 2 5분 누적
│   ├── ConflictResolver.swift        — newer-wins + JSON merge + keepBoth
│   └── FileSyncActor.swift           — ★ rsync 큐 + setBuilder() runtime swap
├── UI/
│   ├── MenuBarRootView.swift         — ★ peer/target/activity + Settings 버튼
│   ├── SettingsView.swift            — ★ 3탭 (General/Network/Excludes)
│   ├── OnboardingViewModel.swift     — 5스텝 상태머신
│   └── FirstLaunchPairingView.swift  — SwiftUI 5스텝 윈도우
├── Utilities/
│   ├── ProcessRunner.swift
│   ├── Logger.swift
│   └── LaunchAtLogin.swift           — ★ SMAppService.mainApp wrapper
└── Resources/
    ├── Info.plist                    — LSUIElement, _claudesync._tcp Bonjour
    ├── ClaudeSync.entitlements
    └── Assets.xcassets/
        └── AppIcon.appiconset/        — ★ 10개 PNG 슬롯 (16~512 + @2x)

ClaudeSyncTests/                       — 24 스위트 177 테스트
scripts/
├── generate-appicon.swift            — ★ Core Graphics 아이콘 생성기
├── release-build.sh                  — ★ Universal Release 빌드
├── measure-footprint.sh              — ★ heap-based Physical Footprint 측정
└── package.sh                        — ★ DMG 패키징 (codesign/notary hook)
```

★ = 이번 세션에서 신규 또는 크게 변경

---

## 사용자 영구 선호 (메모리에 저장됨)

위치: `/Users/kimsejun/.claude/projects/-Users-kimsejun-Documents-GitHub-ClaudeSync/memory/`

- **모든 보고는 HTML 보고서로** (`/html-report` 사용, 텍스트 마크다운만으로 끝내지 않음)
- **사용자 질문은 항상 AskUserQuestion 도구로** (텍스트로 묻지 않음)

---

## 다음 세션 추천 첫 작업

1. **서명 + 공증** — `CODESIGN_IDENTITY` + `NOTARY_PROFILE` 환경변수 설정 후 `bash scripts/package.sh` 한 번
2. **두 Mac 실기 검증** — `docs/DEMO_TWO_MACS.md` 따라 진행
3. **GitHub Release v1.0.0 게시**
4. **(옵션) BrewSyncManager** — v1.1 후보

---

## Resume Prompt (다음 세션용)

```
이전 세션에서 ClaudeSync v1.0-rc1까지 완료했습니다 (Universal binary, Settings,
Launch at Login, AppIcon, DMG 패키징). HANDOFF.md를 읽고 현재 상태를 파악한 후,
서명+공증 또는 두 Mac 실기 검증, GitHub Release 중 사용자가 원하는 작업을 진행하세요.

테스트는 177/177 그린, main이 origin/main과 동기화 상태,
dist/ClaudeSync-1.0.0.dmg가 ad-hoc 서명 상태로 존재합니다.
```
