# ClaudeSync — Handoff Document

## Project Status: v1.1.0 도달 — 다층 보안 + 자동 복구 + 단일 인스턴스 + 실작동 검증

### 마지막 세션 (2026-05-05) 성과 요약

| 지표 | 값 |
|------|------|
| 완료된 Phase | 1~6 + v0.2 + v0.3 + v1.0-rc1 + v1.0.1 + **v1.1.0** |
| 테스트 스위트 / 테스트 | 26 / **214 PASS** (193 → 214, +21 신규) |
| HTML 보고서 | 8개 (`docs/reports/`) |
| Release 빌드 | Universal binary, 4.7MB bundle, **1.7MB DMG** |
| Idle Memory Footprint | **25.2MB** (PRD G4 50MB 대비 50% margin) |
| 0 leaks 유지 | ✅ |

### v1.1.0 신규 기능

기존 v1.0.1 기능 모두 유지 +

**보안 다층 방어 (SEC-002/003/005/009)**:
1. **Bonjour control channel TLS** — TLSCertificateProvider가 self-signed P-256 cert를 openssl로 생성, NWConnection에 NWProtocolTLS.Options 적용. 페어링 후 cert SHA-256 핀 검증
2. **페어링 nonce 교환** — 16-byte 랜덤 nonce를 PairRequest/Accept payload에 포함, 코드 derive에 합산 → replay/pre-computation 차단
3. **단일 시도 enforcement** — 한 세션에서 최대 1개 pairRequest 처리, 이후 .failed
4. **ssh-keyscan known_hosts** — 페어링 완료 시 peer SSH host key를 ~/.claudesync/ssh/known_hosts에 등록, rsync는 StrictHostKeyChecking=yes로 전환 (TOFU accept-new 제거)
5. **HMAC for preferences.json** — ~/.claudesync/.machine-key (HMAC-SHA256)로 signature sidecar, 변조 탐지 시 default fallback

**자동 복구 (RCA-M5/M6/M7/M9)**:
6. **NWPathMonitor** — Wi-Fi flap 시 자동 discovery 재시작 (3s cooldown)
7. **NSWorkspace sleep/wake** — 슬립 전 Bonjour 정리, 깨어난 후 재시작
8. **listener/browser .failed 자동 복구** — explicit event + restart with backoff
9. **Clock skew 검출** — 페어링 시 ±30s 초과 wall-clock 차이면 거부 (newer-wins ConflictResolver 보호)

**작동 검증 (사용자 요청)**:
10. **Single-instance enforcement** — NSRunningApplication + PID sentinel 두 단계 검증, 중복 launch 즉시 차단 + 기존 인스턴스 활성화
11. **Pre-pair UX fix** — peer 없을 때 sync job silently drop (이전엔 "no peer configured" 빨간 X 5개로 누적)
12. **setPeer(nil) drains queue** — Forget paired peer 시 stale job 정리

### 실 작동 검증 결과 (사용자 요청 대응)

| 검증 항목 | 결과 |
|----------|------|
| 메뉴바 트레이 등장 | ✅ (사용자 v1.0.1 스크린샷에서 확인) |
| Bonjour `_claudesync._tcp` 광고 | ✅ (dns-sd로 UUID 발견) |
| Physical Footprint | ✅ **25.2 MB** (PRD G4 50MB 충족) |
| 중복실행 차단 | ✅ 즉시 stderr 메시지 + exit |
| Sentinel 권한 | ✅ 0o600 |
| Stale PID 자동 처리 | ✅ kill(pid, 0) check |
| 214/214 테스트 | ✅ |
| Universal binary | ✅ arm64 + x86_64 |
| DMG 패키징 | ✅ 1.7 MB |
| 0 memory leaks | ✅ |

### v1.0 final 출하 잔여 (사용자 자격증명 필수)

- [ ] Developer ID Application 서명 (`CODESIGN_IDENTITY`)
- [ ] xcrun notarytool 공증 (`NOTARY_PROFILE`)
- [ ] 두 Mac 실기 검증 (`docs/DEMO_TWO_MACS.md`)
- [ ] `gh release create v1.1.0 dist/ClaudeSync-1.1.0.dmg`
- [ ] 72시간 dogfood 안정성 테스트

### v1.2 후보 (의도적 보류)

- TLS cert pinning을 PairedPeerRecord에 영속화 (현재는 in-memory)
- AppIcon: placeholder를 디자이너 작업물로
- Settings에 sync 일시정지 / 충돌 보관함 정리 UI
- BrewSyncManager / NpmGlobalSyncManager
- Bandwidth limit slider UI 개선

---

## v1.1.0 누적 패치 통계

| 마일스톤 | 신규 코드 | 테스트 | 핵심 가치 |
|---------|---------|------|---------|
| v1.0-rc1 | Universal binary, Settings, Launch at Login, AppIcon, DMG | 177 | 출하 가능 형태 |
| v1.0.1 | 페어링 UI 활성화, sync loop 차단, SSH wrapper, hostname 안전, +12 fix | 193 | 실 페어링 가능 |
| **v1.1.0** | TLS, nonce, known_hosts, HMAC, auto recovery, single-instance | **214** | **실 운영 가능** |

---

## Quick Start (다음 세션)

```bash
cd /Users/kimsejun/Documents/GitHub/ClaudeSync
git pull
xcodegen generate
xcodebuild -scheme ClaudeSync -configuration Debug -destination 'platform=macOS' test
# → 214/214 PASS

# v1.1.0 release 빌드 + DMG (서명/공증 없이도 동작)
bash scripts/package.sh
# → dist/ClaudeSync-1.1.0.dmg

# 두 Mac 실기 검증
# 양쪽 Mac에 ClaudeSync.app 복사 → 실행
# 메뉴바 트레이 등장 → "Pair" 버튼 → 6자리 코드 양쪽 표시
# 양쪽이 코드 확인 → "Confirm" → 자동 SSH 키 교환 + TLS handshake + sync 시작
```

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
| v1.0.1 보고서 | `docs/reports/2026-05-05-v1.0.1-quality-pass.html` |
| **v1.1.0 보고서** | `docs/reports/2026-05-05-v1.1.0-defense-in-depth.html` |

---

## 사용자 영구 선호 (메모리에 저장됨)

- 모든 보고는 HTML 보고서로 (`/html-report` 사용)
- 사용자 질문은 항상 AskUserQuestion 도구로

---

## Resume Prompt (다음 세션용)

```
이전 세션에서 ClaudeSync v1.1.0까지 완료했습니다 (TLS, nonce,
known_hosts, HMAC, auto recovery, single-instance enforcement, 그리고
실 작동 검증). HANDOFF.md를 읽고 현재 상태를 파악한 후, 서명+공증,
두 Mac 실기 검증, GitHub Release 중 사용자가 원하는 작업을 진행하세요.

테스트 214/214 그린, dist/ClaudeSync-1.1.0.dmg가 ad-hoc 서명 상태로
존재합니다. v1.1.0에서 8개 카테고리 보안/안정성 이슈를 모두 패치했고
실 환경에서 메뉴바·Bonjour·중복실행 차단까지 검증 완료했습니다.
```
