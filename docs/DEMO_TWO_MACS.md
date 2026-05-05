# 두 Mac 실기 페어링 + 동기화 시연 가이드

이 문서는 사용자가 직접 **MacBook Pro ↔ MacBook Air** 두 대에서 ClaudeSync의 페어링과 동기화를 검증하는 절차입니다. Phase 5까지의 구현이 모두 정상 동작하는지를 확인할 수 있습니다.

> **Note:** 현재 ClaudeSyncApp은 Phase 5 SyncCoordinator를 AppEnvironment에 자동 wiring하지 않습니다 (UI 결합은 Phase 6 예정). 본 가이드는 (a) **빌드된 .app 실행으로 메뉴바 + 온보딩 UI 시연**, (b) **xcodebuild test로 라이브 페어링/동기화 검증**, (c) **CLI에서 rsync 직접 호출로 SSH 전송 검증**의 세 단계로 진행합니다.

---

## 사전 조건 (양 Mac)

```bash
# 1. Remote Login (sshd) 활성화 확인
ssh -o BatchMode=yes -o ConnectTimeout=5 localhost "echo ok"
# → "ok" 출력되면 OK. "Permission denied" 도 OK (sshd는 살아있음).
# → "Connection refused" → System Settings → General → Sharing → Remote Login ON

# 2. rsync 확인 (macOS Sequoia+에는 openrsync, Homebrew rsync 권장)
which rsync
rsync --version | head -1
# 권장: brew install rsync (full GNU 3.x)

# 3. 두 Mac이 같은 WiFi에 있는지 확인 (Bonjour는 LAN-local)
ping -c 1 OtherMacName.local
```

---

## 시나리오 A — 메뉴바 트레이 + 온보딩 UI

### 양 Mac에서:

```bash
# 1. 프로젝트 클론
git clone https://github.com/Two-Weeks-Team/ClaudeSync.git
cd ClaudeSync

# 2. xcodegen으로 프로젝트 생성 (한 번만)
brew install xcodegen
xcodegen generate

# 3. 빌드
xcodebuild -scheme ClaudeSync -configuration Debug build

# 4. 앱 실행
APP=$(xcodebuild -scheme ClaudeSync -configuration Debug -showBuildSettings 2>/dev/null \
  | grep "BUILT_PRODUCTS_DIR" | awk -F= '{print $2}' | xargs)
"$APP/ClaudeSync.app/Contents/MacOS/ClaudeSync" &
```

**기대 결과**
- 메뉴바에 SF Symbol 아이콘 표시 (idle: `circle.dashed`)
- 클릭 시 320pt 팝오버: 헤더 / Status: "Idle" / `Open Onboarding` / `Quit ClaudeSync`
- `Open Onboarding` 클릭 → `FirstLaunchPairingView` 윈도우 표시 (5스텝 — Welcome / Remote Login preflight / FDA preflight / 피어 검색 / 페어링 코드)

### 종료
```bash
pkill -x ClaudeSync
```

---

## 시나리오 B — xctest 기반 자동 페어링 시연 (한 Mac에서)

이미 통과하는 두 개의 풀 E2E 테스트가 있습니다.

```bash
xcodebuild -scheme ClaudeSync -configuration Debug \
  -destination 'platform=macOS' test \
  -only-testing ClaudeSyncTests/EndToEndPairingTests \
  -only-testing ClaudeSyncTests/EndToEndSyncTests
```

**기대 결과**
- `EndToEndPairingTests.testFullPairingHandshake_endToEnd` — 두 격리 환경의 PairingManager가 LoopbackPeerChannel로 핸드셰이크 → 양측 6자리 코드 일치 → 양 authorized_keys에 `restrict,command="rsync --server" claudesync@MacBookPro/Air` 라인 설치 검증
- `EndToEndSyncTests.testFullPipeline_localFileChange_replicatesToPeerDirectoryViaRsync` — 실제 rsync로 source/ → peer/ 파일 전송 + delete 전파

---

## 시나리오 C — 실 SSH로 두 Mac 사이 rsync 시연

이 단계는 **실제 두 Mac이 LAN으로 연결된** 상태가 필요합니다. ClaudeSync 페어링이 실제 두 Mac에서 어떻게 동작하는지를 수동으로 시뮬레이션합니다.

### Step 1 — Mac A (송신측)에서 ClaudeSync SSH 키 생성

```bash
# ClaudeSync 전용 키 (사용자의 SSH 키와 분리)
mkdir -p ~/.claudesync/ssh
chmod 700 ~/.claudesync/ssh
ssh-keygen -t ed25519 \
  -f ~/.claudesync/ssh/id_claudesync \
  -N "" \
  -C "claudesync@$(hostname -s)"
chmod 600 ~/.claudesync/ssh/id_claudesync
ssh-keygen -lf ~/.claudesync/ssh/id_claudesync.pub -E sha256
# → SHA256 fingerprint 출력 (페어링 코드 검증용)
```

### Step 2 — Mac B (수신측)에 Mac A의 공개키 설치

```bash
# Mac A에서 .pub 파일 내용 복사 (또는 scp/AirDrop으로 전달)
cat ~/.claudesync/ssh/id_claudesync.pub
```

Mac B에서:
```bash
# ClaudeSync가 실제 사용할 restrict,command 형식
mkdir -p ~/.ssh
chmod 700 ~/.ssh

cat >> ~/.ssh/authorized_keys <<'EOF'
restrict,command="/usr/bin/rsync --server ${SSH_ORIGINAL_COMMAND#*--server }",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA...실제키내용... claudesync@MacA
EOF
chmod 600 ~/.ssh/authorized_keys
```

### Step 3 — Mac A에서 Mac B로 rsync 시연

```bash
# 시연용 디렉터리 생성 (~/.claude/는 실 데이터라 주의)
mkdir -p ~/claudesync-demo/source
mkdir -p ~/claudesync-demo/dest  # peer쪽 디렉터리는 Mac B에 만들기
echo "Hello from Mac A — $(date)" > ~/claudesync-demo/source/test.txt

# Mac A에서 rsync over SSH (ClaudeSync가 만드는 것과 동일한 명령)
rsync \
  --archive --compress --delete --update --itemize-changes --partial --timeout=30 \
  -e "ssh -i ~/.claudesync/ssh/id_claudesync \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -p 22" \
  ~/claudesync-demo/source/ \
  $(whoami)@MacBookAir.local:~/claudesync-demo/dest/
```

**기대 결과**
- 비밀번호 요청 없이 즉시 전송
- itemize-changes 출력: `>f+++++++++ test.txt`
- Mac B의 `~/claudesync-demo/dest/test.txt`에 동일 내용 존재
- `restrict,command="..rsync --server.."` 가드 덕분에 같은 키로 임의 명령은 거부됨:
  ```bash
  ssh -i ~/.claudesync/ssh/id_claudesync $(whoami)@MacBookAir.local "ls"
  # → "This account is currently not available." 또는 disabled
  ```

### Step 4 — 동기화 페어링 코드 검증 (선택)

Mac A의 공개키와 Mac B의 공개키 raw 32바이트로 6자리 코드를 양측에서 계산 비교:

```bash
# 양 Mac에서 동일한 입력으로 같은 코드가 나와야 함
swift -e '
import Foundation
import CryptoKit

let initiatorPub: Data = ... // Mac A pubkey raw 32B
let responderPub: Data = ... // Mac B pubkey raw 32B
var combined = Data()
combined.append(initiatorPub)
combined.append(responderPub)
let digest = SHA256.hash(data: combined)
let v = digest.prefix(4).reduce(into: UInt32(0)) { $0 = ($0 << 8) | UInt32($1) }
print(String(format: "%06u", v % 1_000_000))
'
```

또는 ClaudeSyncTests의 `PairingCodeGeneratorTests`가 같은 알고리즘을 검증하므로, xctest 결과로 갈음 가능.

---

## 완료 체크리스트

- [ ] 양 Mac에서 메뉴바 아이콘 표시
- [ ] 양 Mac에서 클릭 → 팝오버 정상
- [ ] `Open Onboarding` → 5스텝 플로우 렌더링
- [ ] xctest 89개(+E2E pairing) 양 Mac에서 통과
- [ ] Mac A → Mac B rsync over SSH 비밀번호 없이 성공
- [ ] restrict,command 가드 검증 (임의 ssh 명령 거부)
- [ ] 페어링 코드 양 측 일치

---

## 알려진 제약 (Phase 6 예정)

- ClaudeSyncApp은 SyncCoordinator를 자동 부팅하지 않음 — 메뉴바 UI에서 "Start Sync" 버튼 wiring 필요
- FirstLaunchPairingView의 "Codes match — pair" 버튼이 PairingManager.confirmCode() 미연결
- 페어링 자동 완료 후 SSHKeyManager.installPeerKey()가 실행되지만 자동 시작은 트리거 안 됨
- BatchAccumulator(Tier 2 5분)의 외부 stream wire-up은 Coordinator 내부 placeholder

위 4개 항목은 Phase 6 (UI 통합 + Settings + Launch at Login)에서 완성됩니다.
