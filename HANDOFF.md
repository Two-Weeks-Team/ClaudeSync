# ClaudeSync — Handoff Document

## Project Status: v1.0.1 도달 — 페어링 UI 활성화 + sync loop 차단 + SSH 보안 강화

### 마지막 세션 (2026-05-05) 성과 요약

| 지표 | 값 |
|------|------|
| 완료된 Phase | **1, 2, 3, 4, 5, 6** + v0.2 wiring + v0.3 자동 페어링 + v1.0 hardening + **v1.0.1 quality pass** |
| 테스트 스위트 / 테스트 | 25 / **193 PASS** (177 → 193, +16 신규 v1.0.1 회귀) |
| HTML 보고서 | 7개 (`docs/reports/`) |
| 마일스톤 | v0.1 MVP → v0.2 → v0.3 → v1.0-rc1 → **v1.0.1** |
| Release 빌드 | Universal binary (arm64 + x86_64), 4.6MB bundle, 1.6MB DMG |
| Idle Memory Footprint | **23.5MB** (PRD G4 50MB 충족) |

### v1.0.1에서 작동하는 새 기능

기존 v1.0-rc1 기능 모두 유지 +

**페어링 흐름 정상화 (이전엔 silent no-op)**:
1. **Onboarding 페어링 버튼이 실제로 동작** (RCA-C1) — 이전엔 OnboardingViewModel의 콜백이 nil이라 Accept/Confirm/Reject가 아무것도 안 함
2. **메뉴바에 incoming pairing UI** (RCA-C2) — responder Mac이 메뉴바 popover에서 직접 코드 확인 + 수락 가능
3. **Onboarding window의 discovery step에 발견된 peer 인라인 표시 + Pair 버튼**
4. **Settings에 Paired peer 정보 + Forget 버튼**

**상태 영속화 (RCA-C3)**:
5. **PairedPeerRecord가 ~/.claudesync/preferences.json에 영속** — 앱 재시작 후 자동 복원, FileSyncActor 즉시 재배선
6. **부팅 시 saved peer 발견하면 SyncCoordinator가 .projects 포함 4 target 모두 watch**

**Sync loop 차단 (CR-C2 / RCA-M11)**:
7. **mtime-stale echo filter** — rsync `--archive`가 보존하는 source mtime을 활용해 두 Mac ping-pong 방지. 5초 이상 오래된 mtime의 FSEvents는 echo로 판단해 drop
8. **rsync exit 0 + 0 transferred 검증** — itemize-changes 라인 카운트로 false-success 차단

**SSH/Bonjour 보안 (SEC-001/004/006/007/008/010)**:
9. **rsync-server wrapper script** (~/.claudesync/bin/) — authorized_keys command가 정적 wrapper 가리킴. 위험 인자(--config, --rsh, --daemon)와 셸 메타문자 차단
10. **hostname/username allow-list** (`^[a-zA-Z0-9._-]+$`) — 페어링 전후 양 단계에서 검증, 셸 인젝션 차단
11. **Bonjour-safe local hostname** — `Host.current().localizedName`의 공백 대신 `.local` 시스템 이름 사용
12. **.env / .env.* 보안 exclude 추가** + .aws/credentials, .gnupg/*, *_secret*/*_token* 등
13. **case-insensitive 매칭** — HFS+/APFS 기본 case-insensitive에 대응
14. **rsync exclude 순서**: security 먼저 → per-target → user extras (사용자 패턴이 보안 패턴 shadow 불가)
15. **rsync filter 순서**: --include 먼저 --exclude 나중 (first-match-wins 정합)
16. **log 파일 0o600 / preferences.json 0o600** — 같은 Mac 다른 user 변조 차단

**기타 안정성 (CR-I1/I2, PairingManager)**:
17. **PairRequestPayload.sshPort 추가** — 비표준 sshd 포트 양방향 지원 (이전엔 always 22)
18. **PairingManager force unwrap 제거** — 빈 키로 인한 false code-match 차단 (보안 critical)
19. **NWConnectionPeerChannel deadlock fix** — incomingMessages() 두 번째 호출 시 lock 안에서 finish() 호출하던 dead-lock 패턴 해결

### v1.0 final 출하 잔여 작업 (사용자 자격증명 필수)

- [ ] Developer ID Application 서명 (`CODESIGN_IDENTITY`)
- [ ] xcrun notarytool 공증 (`NOTARY_PROFILE`)
- [ ] 두 Mac 실기 검증 (`docs/DEMO_TWO_MACS.md`)
- [ ] `gh release create v1.0.1 dist/ClaudeSync-1.0.1.dmg`
- [ ] 72시간 dogfood 안정성 테스트

### v1.1 후보 (이번에 의도적으로 보류)

- TLS on Bonjour control channel (SEC-002 — 구조 변경 큼)
- 페어링 코드에 session nonce 추가 (SEC-003 — 프로토콜 변경)
- ssh-keyscan 기반 known_hosts 사전 등록 (SEC-005 — 페어링 흐름 변경)
- NWPathMonitor 기반 네트워크 변화 자동 복구 (RCA-M6)
- NSWorkspace sleep/wake 자동 복구 (RCA-M7)
- Clock skew 검출 + UI 경고 (RCA-M9)
- BrewSyncManager / NpmGlobalSyncManager
- AppIcon: placeholder를 디자이너 작업물로 교체

---

## v1.0.1 핵심 결정: 4명 전문가 패널의 발견

작업 시작 전 4명의 전문가 에이전트(code-reviewer / quality-engineer / security-engineer / root-cause-analyst)를 **병렬**로 스폰해 광범위 스캔. 가장 충격적인 발견:

**"페어링이 silent no-op으로 동작 중"** (root-cause-analyst RCA-C1, C2, C3) — 사용자가 "지난 세션에서 본 에러"의 정체. v1.0-rc1까지의 코드는 빌드/테스트는 통과했지만 실 사용 시:
- Onboarding window의 Accept/Confirm/Reject 버튼이 콜백 미연결로 무반응
- Responder Mac에는 incoming pairing 확인 UI 자체가 없음 (메뉴바에는 outgoing Pair만)
- 페어링 성공해도 앱 재시작하면 잊어버림

이 3개를 v1.0.1의 ship-blocker로 판정하고 정상화. 그 외 16개 issue는 보안/안정성 카테고리로 분류해 일괄 처리.

---

## Quick Start (다음 세션)

```bash
cd /Users/kimsejun/Documents/GitHub/ClaudeSync
git pull
xcodegen generate
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test
# → 193/193 PASS

# v1.0.1 release 빌드 + DMG (서명/공증 없이도 동작)
bash scripts/package.sh
# → dist/ClaudeSync-1.0.1.dmg

# 두 Mac 실기 검증
# 1) ClaudeSync.app을 두 Mac에 복사
# 2) 양쪽에서 실행 → 메뉴바 트레이 등장
# 3) 한쪽에서 메뉴바 popover의 "Pair" 클릭 → 6자리 코드 양쪽 표시
# 4) 양쪽이 코드 확인 → "Confirm" → 자동 SSH 키 교환 + sync 시작
```

---

## Repository

- **GitHub**: https://github.com/Two-Weeks-Team/ClaudeSync
- **Local**: /Users/kimsejun/Documents/GitHub/ClaudeSync
- **Branch**: main (origin/main 동기화 예정)

---

## 핵심 문서

| 문서 | 경로 |
|------|------|
| PRD | `docs/prd/PRD.md` |
| Technical Spec | `docs/specs/TECHNICAL_SPEC.md` |
| Test Strategy | `docs/specs/TEST_STRATEGY.md` |
| 두 Mac 실기 시연 가이드 | `docs/DEMO_TWO_MACS.md` |
| Phase 1~6 보고서 | `docs/reports/*-completion.html` |
| v1.0-rc1 보고서 | `docs/reports/2026-05-05-v1.0-rc1-hardening.html` |
| **v1.0.1 보고서** | `docs/reports/2026-05-05-v1.0.1-quality-pass.html` |

---

## 사용자 영구 선호 (메모리에 저장됨)

- 모든 보고는 HTML 보고서로 (`/html-report` 사용)
- 사용자 질문은 항상 AskUserQuestion 도구로

---

## Resume Prompt (다음 세션용)

```
이전 세션에서 ClaudeSync v1.0.1까지 완료했습니다 (페어링 UI 정상화,
sync loop 차단, SSH 보안 강화, 19개 이슈 패치). HANDOFF.md를 읽고
현재 상태를 파악한 후, 서명+공증, 두 Mac 실기 검증, GitHub Release
중 사용자가 원하는 작업을 진행하세요.

테스트 193/193 그린, dist/ClaudeSync-1.0.1.dmg가 ad-hoc 서명 상태로
존재합니다. v1.0-rc1 → v1.0.1로 가면서 19개 이슈를 패치했고
페어링이 처음으로 실 사용 가능 상태에 도달했습니다.
```
