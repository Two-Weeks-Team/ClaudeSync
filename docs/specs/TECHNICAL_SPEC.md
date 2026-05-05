# ClaudeSync Technical Specification

**Version**: 1.0.0  
**Date**: 2026-05-03  
**Status**: Draft  
**Target Platform**: macOS 14.0+ (Sonoma), Apple Silicon and Intel  
**Recommended Platform**: macOS 15.0+ (Sequoia)  

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Flow](#2-data-flow)
3. [Sync Protocol](#3-sync-protocol)
4. [Bonjour Discovery Protocol](#4-bonjour-discovery-protocol)
5. [Pairing Protocol](#5-pairing-protocol)
6. [SyncTarget Enum](#6-synctarget-enum)
7. [Conflict Resolution](#7-conflict-resolution)
8. [State Machine](#8-state-machine)
9. [Error Handling](#9-error-handling)
10. [Security](#10-security)
11. [Performance](#11-performance)
12. [Key Type Signatures](#12-key-type-signatures)

---

## 1. Architecture Overview

### System Context

ClaudeSync is a native macOS menu bar application that synchronizes AI coding tool environments (Claude Code, Codex, project files) between exactly two Macs on a local network. It uses Bonjour for zero-configuration peer discovery, SSH for secure transport, and rsync for efficient delta file synchronization.

### Design Principles

- **Zero external dependencies**: Only Apple frameworks (SwiftUI, Network.framework, Foundation) and system binaries (rsync, ssh, ssh-keygen)
- **No sandbox**: Distributed outside the App Store to access `~/.claude/`, `~/Library/`, and arbitrary project paths
- **Actor-based concurrency**: Swift 6 strict concurrency with isolated actors for each subsystem
- **Unidirectional data flow**: Events flow through SyncCoordinator; UI observes published state
- **Fail-safe defaults**: Network failures pause sync; never corrupt or delete user data

### Concurrency Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        @MainActor                                │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ SyncCoordinator (ObservableObject)                        │   │
│  │   - Published state for SwiftUI                           │   │
│  │   - Receives events from all actors                       │   │
│  │   - Dispatches user actions to actors                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│              ▲              ▲              ▲                     │
└──────────────┼──────────────┼──────────────┼─────────────────────┘
               │              │              │
    ┌──────────┴──┐   ┌──────┴──────┐  ┌───┴────────────┐
    │FileWatcher  │   │PeerDiscovery│  │FileSyncActor   │
    │Actor        │   │Actor        │  │                │
    │(FSEvents)   │   │(NWBrowser,  │  │(rsync queue)   │
    │             │   │ NWListener) │  │                │
    └─────────────┘   └─────────────┘  └────────────────┘
```

### Module Dependency Graph

```
App (ClaudeSyncApp, AppEnvironment)
 └── Coordinator (SyncCoordinator)
      ├── Discovery (PeerDiscoveryActor, PeerInfo, PairingManager)
      ├── FileWatcher (FileWatcherActor, WatchedPath)
      ├── Sync (FileSyncActor, SyncTarget, SyncJob, SyncResult, ConflictResolver, IgnorePatterns)
      ├── PackageSync (BrewSyncManager, NpmGlobalSyncManager)
      ├── SSH (SSHKeyManager)
      ├── Persistence (AppState, SyncHistory)
      └── Utilities (ProcessRunner, Logger, Debouncer)

UI (MenuBarView, StatusIconProvider, PeerStatusRow, SyncTargetRow, EnvironmentDiffView, FirstLaunchPairingView)
 └── Observes: SyncCoordinator (read-only binding)
```

---

## 2. Data Flow

### Primary Sync Flow: File Change to Peer

```
Step 1: FSEvents Callback
────────────────────────
FSEventStreamCallback fires on kernel event
  → FileWatcherActor receives raw event flags + paths
  → Filters against IgnorePatterns (node_modules, .git/objects, etc.)
  → Normalizes paths, deduplicates within same batch
  → Sends batch to Debouncer

Step 2: Debounce (2-second per-path quiet-period)
──────────────────────────────────────────────────
Debouncer uses a 2-second per-path quiet-period: for each path, the timer
resets on every new event. rsync is only triggered when no new events arrive
for a given path within 2 seconds. This prevents rapid-fire syncs during
IDE autosave, builds, and batch operations while keeping latency under the
3-second sync target (2s debounce + <1s rsync for small files).
  → On timer fire, coalesces overlapping directory events
  → Emits Set<WatchedPath> to SyncCoordinator via AsyncStream

Step 3: SyncCoordinator Routing
───────────────────────────────
@MainActor SyncCoordinator receives debounced path set
  → Maps each path to its SyncTarget
  → Checks SyncTarget.isEnabled in AppState
  → Checks peer connection status == .connected
  → Creates SyncJob(target:, paths:, direction: .push, priority:)
  → Enqueues to FileSyncActor

Step 4: FileSyncActor Execution
───────────────────────────────
FileSyncActor dequeues SyncJob by priority
  → Constructs rsync command (see Section 3)
  → Spawns Foundation.Process with SSH transport
  → Streams stdout/stderr via pipes
  → Parses rsync output for transferred file count and errors
  → Emits SyncResult back to SyncCoordinator

Step 5: Result Processing
─────────────────────────
SyncCoordinator receives SyncResult
  → Updates SyncHistory (last sync time, files transferred, bytes)
  → Updates UI state (SyncStatus per target)
  → If SyncResult.conflicts is non-empty → routes to ConflictResolver
  → Publishes updated state to SwiftUI
```

### Reverse Flow: Receiving Changes from Peer

```
Peer pushes via rsync-over-SSH → local rsync daemon writes files
  → FSEvents fires for received files
  → FileWatcherActor recognizes paths match in-flight SyncJob.receivedPaths
  → Marks as "received, do not re-sync" (echo suppression)
  → SyncCoordinator updates UI with received file count
```

### Echo Suppression Mechanism

To prevent infinite sync loops when receiving files triggers FSEvents, suppression is keyed to the rsync process lifecycle rather than a fixed timer. This ensures suppression lasts exactly as long as needed (large files take longer) and is released promptly for small files.

```swift
actor FileWatcherActor {
    /// Maps destination path -> set of active rsync PIDs writing to that path
    private var activeRsyncPIDs: [String: Set<pid_t>] = [:]
    
    /// Paths recently released from suppression; 1s buffer after process exit
    private var releaseBuffers: [String: ContinuousClock.Instant] = [:]
    
    /// Called by FileSyncActor when rsync process starts writing to a path
    func registerRsyncProcess(pid: pid_t, for paths: Set<String>) {
        for path in paths {
            activeRsyncPIDs[path, default: []].insert(pid)
        }
    }
    
    /// Called by FileSyncActor when rsync process exits (success or failure)
    func unregisterRsyncProcess(pid: pid_t, for paths: Set<String>) {
        for path in paths {
            activeRsyncPIDs[path]?.remove(pid)
            if activeRsyncPIDs[path]?.isEmpty == true {
                activeRsyncPIDs.removeValue(forKey: path)
                // Start 1-second buffer period after last rsync exits
                releaseBuffers[path] = .now
            }
        }
    }
    
    private func shouldSuppress(_ path: String) -> Bool {
        // Suppress if an rsync process is actively writing to this path
        if let pids = activeRsyncPIDs[path], !pids.isEmpty {
            return true
        }
        
        // Suppress during the 1-second buffer after rsync exit
        if let releaseTime = releaseBuffers[path] {
            if ContinuousClock.now - releaseTime < .seconds(1) {
                return true
            }
            releaseBuffers.removeValue(forKey: path)
        }
        
        return false
    }
    
    /// On startup: scan for stale suppression markers from previous crashes
    func cleanupStaleMarkers() async {
        let markerDir = URL(filePath: NSHomeDirectory())
            .appending(path: ".claudesync")
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(
            at: markerDir, includingPropertiesForKeys: nil
        ) else { return }
        
        for file in contents where file.lastPathComponent.hasPrefix(".syncing-") {
            // Extract PID from marker filename: .syncing-<pid>
            let pidStr = file.lastPathComponent.replacingOccurrences(of: ".syncing-", with: "")
            if let pid = pid_t(pidStr) {
                // Check if process is still running
                if kill(pid, 0) != 0 {
                    // Process is dead; remove stale marker
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
}
```

---

## 3. Sync Protocol

### rsync Command Construction

#### macOS openrsync Compatibility Note

**Important**: macOS Sequoia (15.0+) replaced GNU rsync with `openrsync`, a BSD-licensed reimplementation. Several commonly-used flags are broken or missing in openrsync:

- `--log-file` — not supported
- `-E` (extended attributes) — not supported
- `--backup-dir` — not supported
- `--checksum-choice` — not supported
- `--compress-choice` — not supported
- `-P` (equivalent to `--partial --progress`) — use `--partial` separately

**Safe flag set for openrsync compatibility**:
```
--archive --compress --delete --update --itemize-changes -e ssh --partial --timeout=30
```

**Optional enhancement**: If Homebrew rsync 3.x is detected at `/opt/homebrew/bin/rsync`, use it for additional features (checksum-choice=xxhash, compress-choice, log-file). Fall back to `/usr/bin/rsync` (openrsync) with the safe flag set.

#### Standard File Sync

```swift
struct RsyncCommandBuilder {
    /// Detect whether Homebrew rsync 3.x is available (preferred)
    private var rsyncPath: String {
        let homebrewPath = "/opt/homebrew/bin/rsync"
        if FileManager.default.fileExists(atPath: homebrewPath) {
            return homebrewPath  // Full GNU rsync feature set
        }
        return "/usr/bin/rsync"  // macOS openrsync (limited flags)
    }
    
    /// Whether we are using Homebrew GNU rsync (supports extended flags)
    private var isGNURsync: Bool {
        rsyncPath.contains("homebrew")
    }
    
    func buildCommand(for job: SyncJob, peer: PeerInfo) -> [String] {
        var args: [String] = [
            rsyncPath,
            "--archive",                     // recursive, preserve permissions/times/etc.
            "--compress",                    // compress during transfer
            "--delete",                      // delete extraneous files on receiver
            "--update",                      // skip files newer on receiver
            "--itemize-changes",             // output change summary for each file
            "--partial",                     // resume interrupted transfers
            "--timeout=30",                  // 30s I/O timeout
            "-e", sshCommand(for: peer),     // SSH transport
        ]
        
        // Add GNU rsync-only flags if available
        if isGNURsync {
            args += ["--delete-after"]       // defer deletion until transfer complete
            args += ["--contimeout=10"]      // 10s connection timeout
        }
        
        // Add exclude patterns for this target
        for pattern in job.target.excludePatterns {
            args += ["--exclude", pattern]
        }
        
        // Add include filters if syncing specific paths
        if !job.paths.isEmpty {
            for path in job.paths {
                let relative = path.relativeTo(job.target.basePath)
                args += ["--include", relative]
            }
            args += ["--include", "*/"]       // include parent dirs
            args += ["--exclude", "*"]        // exclude everything else
        }
        
        // Source and destination
        switch job.direction {
        case .push:
            args.append(job.target.localPath.trailingSlash)
            args.append("\(peer.sshAddress):\(job.target.remotePath.trailingSlash)")
        case .pull:
            args.append("\(peer.sshAddress):\(job.target.remotePath.trailingSlash)")
            args.append(job.target.localPath.trailingSlash)
        }
        
        return args
    }
    
    private func sshCommand(for peer: PeerInfo) -> String {
        "ssh -i \(SSHKeyManager.privateKeyPath) " +
        "-o StrictHostKeyChecking=accept-new " +
        "-o ConnectTimeout=10 " +
        "-o BatchMode=yes " +
        "-p \(peer.sshPort)"
    }
}
```

#### Dry-Run for Conflict Detection

Before pushing, a dry-run detects files modified on both sides:

```swift
func dryRun(for job: SyncJob, peer: PeerInfo) -> [String] {
    var args = buildCommand(for: job, peer: peer)
    args.insert("--dry-run", at: 1)
    args.insert("--itemize-changes", at: 1)
    return args
}
```

Output parsing for conflict detection:

```
>f.st...... path/to/file    → file changed on remote (size/time differ)
```

If a file appears in both local changes AND remote `--itemize-changes`, it is a conflict.

### SSH Tunnel Setup

ClaudeSync does NOT create persistent SSH tunnels. Each rsync invocation uses a fresh SSH connection with ControlMaster for connection reuse within a session:

```swift
struct SSHConfig {
    static let controlPath = "~/.claudesync/ssh/control-%C"
    
    static var sshArgs: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=300",        // keep control socket for 5min
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "BatchMode=yes",             // never prompt for password
            "-o", "StrictHostKeyChecking=accept-new",
            "-i", SSHKeyManager.privateKeyPath,
        ]
    }
}
```

### 3-Tier Sync Architecture

Different file types have different urgency and volume characteristics. The sync engine classifies all paths into three tiers:

| Tier | Latency Target | Files | Debounce | Scheduling |
|------|---------------|-------|----------|------------|
| **Tier 1 (Real-time)** | <3s | `settings.json`, `CLAUDE.md`, `hooks/`, `commands/`, `memory/`, `claude_desktop_config.json`, `~/.codex/` configs | 2s per-path quiet-period | Immediate on debounce fire |
| **Tier 2 (Batched)** | 5 min | `sessions/`, `transcripts/` | Accumulate changes | Flush every 5 minutes or on app quit/sleep |
| **Tier 3 (On-demand)** | Manual/scheduled | `~/Documents/GitHub/`, brew/npm package lists | N/A | User trigger, schedule (30 min default), or wake-from-sleep |

```swift
enum SyncTier: Int, Comparable, Sendable {
    case realtime = 0     // Tier 1: <3s, small critical files
    case batched = 1      // Tier 2: 5-min accumulation, append-only large files
    case onDemand = 2     // Tier 3: scheduled or manual trigger
    
    static func < (lhs: SyncTier, rhs: SyncTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension SyncTarget {
    var tier: SyncTier {
        switch self {
        case .claudeConfig:
            return .realtime  // Note: sessions/ and transcripts/ subpaths override to .batched
        case .claudeAppSupport, .codexConfig:
            return .realtime
        case .projects:
            return .onDemand
        case .brewPackages, .npmGlobals:
            return .onDemand
        }
    }
    
    /// Subpath tier overrides (e.g., sessions/ within claudeConfig is Tier 2)
    func tierForSubpath(_ relativePath: String) -> SyncTier {
        if self == .claudeConfig {
            if relativePath.hasPrefix("sessions/") || relativePath.hasPrefix("transcripts/") {
                return .batched
            }
        }
        return tier
    }
}
```

**Tier 2 Batch Accumulator**:

```swift
actor BatchAccumulator {
    private var pendingPaths: [SyncTarget: Set<String>] = [:]
    private var flushTask: Task<Void, Never>?
    private let flushInterval: Duration = .seconds(300)  // 5 minutes
    
    func accumulate(paths: Set<String>, for target: SyncTarget) {
        pendingPaths[target, default: []].formUnion(paths)
        ensureFlushScheduled()
    }
    
    private func ensureFlushScheduled() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: flushInterval)
            guard !Task.isCancelled else { return }
            await flushAll()
        }
    }
    
    func flushAll() {
        let snapshot = pendingPaths
        pendingPaths.removeAll()
        flushTask = nil
        // Emit accumulated paths to SyncCoordinator for processing
        for (target, paths) in snapshot where !paths.isEmpty {
            // ... emit to coordinator
        }
    }
    
    /// Called on app quit or sleep to ensure no data is lost
    func flushImmediately() async {
        flushTask?.cancel()
        flushTask = nil
        await flushAll()
    }
}
```

### Full Sync vs Incremental Sync

| Mode | Trigger | rsync Flags |
|------|---------|-------------|
| Full Sync | First sync, manual trigger, after conflict resolution | `-azP --delete-after` (full directory) |
| Incremental | FSEvents-triggered, specific paths known | `-azP --files-from=<tempfile>` |

### rsync Output Parsing

```swift
struct RsyncOutputParser {
    struct Progress {
        let bytesTransferred: Int64
        let totalBytes: Int64
        let filesTransferred: Int
        let speedBytesPerSecond: Int64
    }
    
    /// Parse incremental progress line:
    /// "  1,234,567  45%  12.34MB/s  0:00:03"
    func parseProgressLine(_ line: String) -> Progress?
    
    /// Parse completion summary:
    /// "sent 1,234 bytes  received 56 bytes  ..."
    func parseSummary(_ output: String) -> SyncResult
    
    /// Parse itemize-changes for conflict detection:
    /// ">f.st...... relative/path"
    func parseItemizedChanges(_ output: String) -> [FileChange]
}
```

---

## 4. Bonjour Discovery Protocol

### Service Registration

```swift
// Service type: _claudesync._tcp
// Domain: local.
// Full service type string for Network.framework:
let serviceType = "_claudesync._tcp"

// TXT Record fields:
struct BonjourTXTRecord {
    let version: String       // "1" — protocol version
    let machineId: String     // UUID stored in AppState, stable across launches
    let hostname: String      // Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let username: String      // NSUserName()
    let sshPort: String       // "22" or custom port
    let paired: String        // "0" or "1" — whether already paired with another device
    let publicKeyFP: String   // SHA256 fingerprint of this machine's ClaudeSync SSH public key
}
```

### NWBrowser Configuration

```swift
actor PeerDiscoveryActor {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var connection: NWConnection?
    
    func startDiscovery() {
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: "_claudesync._tcp",
            domain: "local."
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: descriptor, using: parameters)
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { await self?.handleBrowseResults(results, changes: changes) }
        }
        browser?.start(queue: .global(qos: .userInitiated))
    }
    
    func startListener() {
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        
        // Add custom framing protocol for length-prefixed JSON
        let framerOptions = NWProtocolFramer.Options(definition: ClaudeSyncProtocol.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)
        
        // Advertise via Bonjour
        listener = try? NWListener(using: parameters)
        listener?.service = NWListener.Service(
            name: machineId,
            type: "_claudesync._tcp",
            domain: "local.",
            txtRecord: buildTXTRecord()
        )
        listener?.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleIncomingConnection(connection) }
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }
}
```

### NWProtocolFramer: Length-Prefixed JSON

All control messages between peers use a custom NWProtocolFramer for reliable message framing:

```swift
class ClaudeSyncProtocol: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ClaudeSyncProtocol.self)
    static var label: String { "ClaudeSync" }
    
    // Wire format:
    // ┌──────────────────────┬──────────────────────────────────┐
    // │ Length (4 bytes, BE)  │ JSON payload (UTF-8)             │
    // └──────────────────────┴──────────────────────────────────┘
    
    required init(framer: NWProtocolFramer.Instance) {}
    
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var header = Data(count: 4)
            let headerComplete = framer.parseInput(
                minimumIncompleteLength: 4,
                maximumLength: 4
            ) { buffer, isComplete in
                if let buffer, buffer.count >= 4 {
                    header = Data(buffer.prefix(4))
                    return 4
                }
                return 0
            }
            guard headerComplete else { return 4 }
            
            let length = header.withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            
            guard length > 0, length <= 1_048_576 else { // 1MB max message
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            
            let message = NWProtocolFramer.Message(definition: Self.definition)
            _ = framer.deliverInputNoCopy(
                length: Int(length),
                message: message,
                isComplete: true
            )
        }
    }
    
    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        var header = Data(count: 4)
        header.withUnsafeMutableBytes {
            $0.storeBytes(of: UInt32(messageLength).bigEndian, as: UInt32.self)
        }
        framer.writeOutput(content: header)
        
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }
    
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
```

### Control Message Schema

```swift
enum ControlMessage: Codable {
    case pairRequest(PairRequestPayload)
    case pairAccept(PairAcceptPayload)
    case pairReject(reason: String)
    case syncNotify(SyncNotifyPayload)
    case syncAck(jobId: UUID)
    case conflictReport(ConflictPayload)
    case conflictResolution(ConflictResolutionPayload)
    case heartbeat(timestamp: Date)
    case disconnect(reason: String)
    case statusRequest
    case statusResponse(PeerStatusPayload)
}

struct PairRequestPayload: Codable {
    let machineId: UUID
    let hostname: String
    let username: String
    let publicKey: String        // Full SSH public key content
    let publicKeyFingerprint: String
    let protocolVersion: Int
}

struct PairAcceptPayload: Codable {
    let machineId: UUID
    let hostname: String
    let username: String
    let publicKey: String
    let sshPort: UInt16
    let syncTargets: [SyncTargetInfo]
}

struct SyncNotifyPayload: Codable {
    let jobId: UUID
    let target: SyncTarget
    let paths: [String]
    let direction: SyncDirection
    let timestamp: Date
}

struct PeerStatusPayload: Codable {
    let machineId: UUID
    let syncStatuses: [SyncTarget: SyncStatus]
    let diskFreeBytes: Int64
    let lastSyncTimestamp: Date?
}

struct ConflictPayload: Codable {
    let jobId: UUID
    let conflictingPaths: [ConflictInfo]
}

struct ConflictInfo: Codable {
    let relativePath: String
    let localModTime: Date
    let remoteModTime: Date
    let localSize: Int64
    let remoteSize: Int64
    let localHash: String       // First 8 bytes of SHA256
    let remoteHash: String
}
```

---

## 5. Pairing Protocol

### Prerequisites

- Both machines running ClaudeSync
- Both on same local network (Bonjour-reachable)
- macOS Remote Login (SSH) enabled on both machines (System Settings > General > Sharing > Remote Login)
- Full Disk Access granted to ClaudeSync (for FSEvents on protected paths)

### Visual Confirmation Code Derivation

The 6-digit pairing confirmation code is derived deterministically from both public keys, allowing both machines to independently compute the same code. If the codes match on both screens, no MITM attack has occurred during key exchange.

```swift
struct PairingCodeGenerator {
    /// Derive 6-digit confirmation code from both public keys.
    /// Code = first 6 decimal digits of SHA-256(pubkey_A_bytes || pubkey_B_bytes)
    /// where A is the initiator and B is the responder.
    static func generateCode(
        initiatorPublicKey: Data,
        responderPublicKey: Data
    ) -> String {
        // Concatenate raw public key bytes in fixed order (initiator || responder)
        var combined = Data()
        combined.append(initiatorPublicKey)
        combined.append(responderPublicKey)
        
        // SHA-256 hash of concatenated keys
        let hash = SHA256.hash(data: combined)
        
        // Extract first 6 decimal digits from hash bytes
        let hashBytes = Array(hash)
        let value = UInt32(hashBytes[0]) << 24
                  | UInt32(hashBytes[1]) << 16
                  | UInt32(hashBytes[2]) << 8
                  | UInt32(hashBytes[3])
        
        let code = value % 1_000_000  // 6-digit code
        return String(format: "%06d", code)
    }
}
```

**Security properties**:
- Both machines independently compute the same code from the exchanged public keys.
- An attacker performing MITM would substitute their own public key, causing a code mismatch.
- The code is displayed on both screens; user must visually confirm they match before accepting.

### Step-by-Step Flow

```
Machine A (Initiator)                    Machine B (Responder)
─────────────────────                    ─────────────────────

1. User clicks "Pair with [Machine B]"
   in menu bar UI

2. SSHKeyManager generates keypair
   if not exists:
   ssh-keygen -t ed25519
     -f ~/.claudesync/ssh/id_claudesync
     -N "" -C "claudesync@hostname"

3. PeerDiscoveryActor sends:           4. Receives PairRequest
   ControlMessage.pairRequest(           Shows notification to user:
     machineId: UUID,                    "Machine A wants to pair"
     hostname: "MacBook-Pro",            with fingerprint display
     username: "kim",
     publicKey: <full ed25519 pub>,
     publicKeyFingerprint: "SHA256:...",
     protocolVersion: 1
   )

                                        5. User clicks "Accept"
                                           SSHKeyManager generates own
                                           keypair if not exists

                                        6. SSHKeyManager appends A's public
                                           key to ~/.ssh/authorized_keys
                                           with restriction:
                                           restrict,command="/usr/bin/rsync ${SSH_ORIGINAL_COMMAND#* }" <key>

                                        7. Sends ControlMessage.pairAccept(
                                             machineId: UUID,
                                             hostname: "iMac",
                                             username: "kim",
                                             publicKey: <full ed25519 pub>,
                                             sshPort: 22,
                                             syncTargets: [enabled targets]
                                           )

8. Receives PairAccept
   SSHKeyManager appends B's public
   key to ~/.ssh/authorized_keys
   with same restriction

9. Verifies SSH connectivity:
   ssh -i ~/.claudesync/ssh/id_claudesync
       -o BatchMode=yes
       -p 22 kim@<B_IP> "echo ok"

10. If verification succeeds:          11. Receives connection verification
    Updates AppState.pairedPeer             Updates own AppState
    Sends syncNotify for initial sync

12. Full initial sync begins
    (both directions, merge strategy)
```

### SSH Key Isolation

ClaudeSync maintains its own keypair separate from the user's default SSH keys:

```
~/.claudesync/
├── ssh/
│   ├── id_claudesync           (private key, 0600)
│   ├── id_claudesync.pub       (public key, 0644)
│   └── control-%C              (SSH ControlMaster sockets)
├── config.json                 (AppState persistence)
└── history.sqlite              (SyncHistory database)
```

### authorized_keys Entry Format

```
restrict,command="rsync --server ${SSH_ORIGINAL_COMMAND#*--server }",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... claudesync@MacBook-Pro
```

The `restrict` prefix disables all capabilities, then `command=` limits to rsync server mode only. This ensures the ClaudeSync key cannot be used for arbitrary remote execution.

### Unpairing Flow

```
1. User clicks "Unpair" in menu
2. Send ControlMessage.disconnect(reason: "user_unpair")
3. Remove peer's public key from ~/.ssh/authorized_keys
4. Close NWConnection
5. Clear AppState.pairedPeer
6. Do NOT delete local SSH keypair (reusable for future pairing)
7. Do NOT delete synced files
```

---

## 6. SyncTarget Enum

```swift
enum SyncTarget: String, Codable, CaseIterable, Identifiable {
    case claudeConfig       // ~/.claude/
    case claudeAppSupport   // ~/Library/Application Support/Claude/
    case codexConfig        // ~/.codex/
    case projects           // ~/Documents/GitHub/
    case brewPackages       // Brewfile-based sync
    case npmGlobals         // npm global package list sync
    
    var id: String { rawValue }
}
```

### Target Specifications

#### claudeConfig (~/.claude/)

```swift
extension SyncTarget {
    // Estimated size: ~3GB (sessions/transcripts dominate)
    static let claudeConfigSpec = SyncTargetSpec(
        basePath: "~/.claude",
        
        watchPaths: [
            "~/.claude/settings.json",
            "~/.claude/CLAUDE.md",
            "~/.claude/commands/",
            "~/.claude/hooks/",
            "~/.claude/skills/",
            "~/.claude/memory/",
            "~/.claude/sessions/",
            "~/.claude/transcripts/",
        ],
        
        excludePatterns: [
            ".claudesync/",              // Our own state directory
            "statsig/",                  // Telemetry cache
            "*.lock",                    // Lock files
            "*.tmp",                     // Temporary files
            "credentials.json",          // Never sync credentials
            "oauth_token*",              // Never sync OAuth tokens
        ],
        
        syncMode: .bidirectional,
        priority: .high,
        debounceMs: 2000,            // 2s per-path quiet-period (Tier 1 standard)
        
        // Large directories use Tier 2 batched sync (5-min accumulation)
        heavySubpaths: [
            "sessions/",                 // Can be GBs — Tier 2 batched
            "transcripts/",              // Can be GBs — Tier 2 batched
        ],
        heavySubpathPriority: .low
    )
}
```

#### claudeAppSupport (~/Library/Application Support/Claude/)

```swift
static let claudeAppSupportSpec = SyncTargetSpec(
    basePath: "~/Library/Application Support/Claude",
    
    watchPaths: [
        "~/Library/Application Support/Claude/",
    ],
    
    excludePatterns: [
        "Cache/",
        "GPUCache/",
        "blob_storage/",
        "*.log",
        "Crashpad/",
        "DawnCache/",
        "Local Storage/",
        "Session Storage/",
        "Service Worker/",
        "WebStorage/",
    ],
    
    syncMode: .bidirectional,
    priority: .high,
    debounceMs: 2000,            // 2s per-path quiet-period (Tier 1 standard)
    heavySubpaths: [],
    heavySubpathPriority: .normal
)
```

Key files synced:
- `claude_desktop_config.json` (MCP server configurations)
- `settings.json` (app-level settings)

#### codexConfig (~/.codex/)

```swift
static let codexConfigSpec = SyncTargetSpec(
    basePath: "~/.codex",
    
    watchPaths: [
        "~/.codex/",
    ],
    
    excludePatterns: [
        "*.log",
        "cache/",
        "*.tmp",
    ],
    
    syncMode: .bidirectional,
    priority: .high,
    debounceMs: 2000,            // 2s per-path quiet-period (Tier 1 standard)
    heavySubpaths: [],
    heavySubpathPriority: .normal
)
```

#### projects (~/Documents/GitHub/)

```swift
static let projectsSpec = SyncTargetSpec(
    basePath: "~/Documents/GitHub",
    
    watchPaths: [
        "~/Documents/GitHub/",
    ],
    
    excludePatterns: [
        "node_modules/",
        ".git/objects/",
        ".git/pack/",
        "*.git/lfs/",
        ".next/",
        ".nuxt/",
        "dist/",
        "build/",
        ".build/",
        "DerivedData/",
        "Pods/",
        ".gradle/",
        "target/",                  // Rust/Java build
        "vendor/",                  // Go vendor
        "__pycache__/",
        "*.pyc",
        ".venv/",
        "venv/",
        ".env.local",
        ".env.*.local",
        "*.o",
        "*.a",
        "*.dylib",
        "*.so",
        ".DS_Store",
        "Thumbs.db",
        "*.swp",
        "*.swo",
    ],
    
    syncMode: .bidirectional,
    priority: .normal,
    debounceMs: 2000,              // 2s per-path quiet-period (Tier 3: on-demand scheduling)
    
    heavySubpaths: [],             // Entire target is potentially heavy
    heavySubpathPriority: .normal,
    
    // Special: per-project .claudesyncignore support
    supportsLocalIgnoreFile: true
)
```

**Estimated size**: ~67GB raw, ~15-25GB after exclusions

**Per-project ignore file** (`.claudesyncignore`):
```
# Follows .gitignore syntax
# Placed at project root: ~/Documents/GitHub/myproject/.claudesyncignore
large-dataset/
*.model
recordings/
```

#### brewPackages (Brewfile)

```swift
static let brewPackagesSpec = SyncTargetSpec(
    basePath: "~/.claudesync/brew",   // Synthetic path for Brewfile
    
    watchPaths: [],                    // No FSEvents; triggered manually or on schedule
    
    excludePatterns: [],
    
    syncMode: .manifest,              // Special: syncs a manifest, not files
    priority: .low,
    debounceMs: 0,                    // Not applicable
    heavySubpaths: [],
    heavySubpathPriority: .low
)
```

**Sync mechanism**:
```swift
actor BrewSyncManager {
    /// Generate current machine's Brewfile
    func generateBrewfile() async throws -> URL {
        // Runs: brew bundle dump --file=~/.claudesync/brew/Brewfile --force
        let process = ProcessRunner(
            executable: "/opt/homebrew/bin/brew",
            arguments: ["bundle", "dump", "--file=\(brewfilePath)", "--force"]
        )
        try await process.run()
        return brewfilePath
    }
    
    /// Compare local and remote Brewfiles, return diff
    func diff(local: URL, remote: URL) async throws -> BrewDiff {
        let localPackages = try parseBrewfile(at: local)
        let remotePackages = try parseBrewfile(at: remote)
        return BrewDiff(
            missingLocally: remotePackages.subtracting(localPackages),
            missingRemotely: localPackages.subtracting(remotePackages),
            versionDifferences: findVersionDiffs(localPackages, remotePackages)
        )
    }
    
    /// Install missing packages (requires user confirmation)
    func installMissing(_ packages: Set<BrewPackage>) async throws {
        for package in packages {
            let process = ProcessRunner(
                executable: "/opt/homebrew/bin/brew",
                arguments: ["install", package.fullName]
            )
            try await process.run()
        }
    }
}
```

#### npmGlobals

```swift
static let npmGlobalsSpec = SyncTargetSpec(
    basePath: "~/.claudesync/npm",    // Synthetic path for package list
    
    watchPaths: [],                    // Triggered manually or on schedule
    
    excludePatterns: [],
    
    syncMode: .manifest,
    priority: .low,
    debounceMs: 0,
    heavySubpaths: [],
    heavySubpathPriority: .low
)
```

**Sync mechanism**:
```swift
actor NpmGlobalSyncManager {
    /// List globally installed packages
    func listGlobals() async throws -> [NpmPackage] {
        // Runs: npm list -g --json --depth=0
        let process = ProcessRunner(
            executable: "/usr/local/bin/npm",
            arguments: ["list", "-g", "--json", "--depth=0"]
        )
        let output = try await process.runAndCapture()
        return try JSONDecoder().decode(NpmGlobalList.self, from: output).packages
    }
    
    /// Diff and present to user
    func diff(local: [NpmPackage], remote: [NpmPackage]) -> NpmDiff
    
    /// Install missing (user-confirmed)
    func installMissing(_ packages: [NpmPackage]) async throws
}
```

### SyncTargetSpec Structure

```swift
struct SyncTargetSpec: Sendable {
    let basePath: String
    let watchPaths: [String]
    let excludePatterns: [String]
    let syncMode: SyncMode
    let priority: SyncPriority
    let debounceMs: Int
    let heavySubpaths: [String]
    let heavySubpathPriority: SyncPriority
    let supportsLocalIgnoreFile: Bool
    
    init(
        basePath: String,
        watchPaths: [String],
        excludePatterns: [String],
        syncMode: SyncMode = .bidirectional,
        priority: SyncPriority = .normal,
        debounceMs: Int = 500,
        heavySubpaths: [String] = [],
        heavySubpathPriority: SyncPriority = .normal,
        supportsLocalIgnoreFile: Bool = false
    ) { /* ... */ }
}

enum SyncMode: String, Codable, Sendable {
    case bidirectional    // Both sides can modify; conflict resolution needed
    case pushOnly         // Only push local changes to peer
    case pullOnly         // Only pull peer changes to local
    case manifest         // Sync a generated manifest, not raw files
}

enum SyncPriority: Int, Codable, Comparable, Sendable {
    case critical = 0    // MCP configs (needed for tools to work)
    case high = 1        // Settings, skills, hooks
    case normal = 2      // Project files
    case low = 3         // Sessions, transcripts, package lists
    case background = 4  // Bulk historical data
}
```

---

## 7. Conflict Resolution

### Conflict Detection

A conflict occurs when the SAME file has been modified on BOTH machines since the last successful sync. Detection uses the rsync dry-run approach:

```swift
struct ConflictDetector {
    /// Returns true if file was modified locally since last sync
    func isLocallyModified(_ path: String, since lastSync: Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return modDate > lastSync
    }
    
    /// Cross-reference local changes with rsync --itemize-changes output
    func detectConflicts(
        localChanges: Set<String>,
        remoteChanges: [FileChange],
        lastSyncTime: Date
    ) -> [ConflictInfo] {
        let remoteSet = Set(remoteChanges.map(\.relativePath))
        let conflicting = localChanges.intersection(remoteSet)
        
        return conflicting.compactMap { path in
            guard let remote = remoteChanges.first(where: { $0.relativePath == path }) else {
                return nil
            }
            return ConflictInfo(
                relativePath: path,
                localModTime: localModTime(for: path),
                remoteModTime: remote.modTime,
                localSize: localSize(for: path),
                remoteSize: remote.size,
                localHash: quickHash(for: path),
                remoteHash: remote.hash
            )
        }
    }
}
```

### Decision Tree

```
File conflict detected for path P
│
├── Are file contents identical (hash match)?
│   └── YES → No real conflict. Update timestamps. Done.
│
├── Is one side a deletion and other a modification?
│   ├── Modified wins (preserve data) → keep modified version
│   └── Write `.claudesync-deleted` marker for UI notification
│
├── Is the file a known "append-only" type?
│   │   (e.g., ~/.claude/memory/*, shell history)
│   └── YES → Three-way merge:
│       ├── Find common ancestor (last synced version from SyncHistory)
│       ├── Compute both diffs from ancestor
│       └── Apply non-overlapping changes; flag overlapping sections
│
├── Is the file JSON/YAML configuration?
│   └── YES → Structural merge:
│       ├── Parse both versions
│       ├── Deep-merge objects (arrays: union by identifier)
│       ├── On key-level conflict: newer timestamp wins
│       └── Write merged result
│
├── Is the file within .claude/sessions/ or transcripts/?
│   └── YES → Both versions are append-only logs
│       └── Keep BOTH: rename remote to filename.peer.ext
│
└── DEFAULT (binary or unresolvable text conflict):
    ├── Strategy = "newer wins" (default):
    │   └── File with later mtime wins; loser saved as filename.conflict.ext
    ├── Strategy = "larger wins" (for binary):
    │   └── File with larger size wins
    └── Strategy = "manual" (user preference):
        └── Both versions saved; user prompted in UI
```

### ConflictResolver Implementation

```swift
actor ConflictResolver {
    enum Strategy: String, Codable, Sendable {
        case newerWins          // Default: most recent modification wins
        case largerWins         // For binary files
        case manual             // User decides
        case merge             // Attempt automatic merge
    }
    
    struct Resolution: Sendable {
        let path: String
        let winner: Winner
        let backupPath: String?  // Path to losing version, nil if merged
        let strategy: Strategy
        
        enum Winner: Sendable {
            case local
            case remote
            case merged(Data)
        }
    }
    
    func resolve(
        conflict: ConflictInfo,
        localPath: URL,
        remotePath: URL,
        strategy: Strategy,
        ancestor: URL?          // Last synced version from history
    ) async throws -> Resolution {
        // Implementation follows decision tree above
    }
    
    /// Determine strategy based on file type and user preferences
    func strategyFor(path: String, userPreference: Strategy?) -> Strategy {
        if let pref = userPreference { return pref }
        
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "json", "yaml", "yml", "toml":
            return .merge
        case "md", "txt", "swift", "py", "js", "ts", "go":
            return .merge
        case "png", "jpg", "pdf", "zip", "tar", "gz":
            return .largerWins
        default:
            return .newerWins
        }
    }
}
```

### Conflict UI Notification

When `strategy == .manual` or merge fails:

```swift
struct ConflictNotification {
    let path: String
    let localVersion: FileVersion
    let remoteVersion: FileVersion
    let suggestedAction: ConflictResolver.Strategy
    
    struct FileVersion {
        let modTime: Date
        let size: Int64
        let preview: String?    // First 500 chars for text files
    }
}
```

---

## 8. State Machine

### SyncStatus Enum

```swift
enum SyncStatus: Equatable, Sendable {
    case idle                           // No activity
    case watching                       // FSEvents active, waiting for changes
    case syncing(progress: SyncProgress) // Active rsync transfer
    case conflict(paths: [String])      // Awaiting resolution
    case error(SyncError)               // Recoverable error state
    case paused                         // User-paused or network unavailable
    case disabled                       // Target disabled by user
    
    struct SyncProgress: Equatable, Sendable {
        let filesTotal: Int
        let filesCompleted: Int
        let bytesTotal: Int64
        let bytesTransferred: Int64
        let currentFile: String?
    }
}
```

### ConnectionStatus Enum

```swift
enum ConnectionStatus: Equatable, Sendable {
    case disconnected                   // No peer found
    case discovering                    // Bonjour browsing active
    case peerFound(PeerInfo)            // Peer visible but not connected
    case connecting                     // TCP connection in progress
    case connected(PeerInfo)            // Active connection, heartbeats OK
    case pairingRequired(PeerInfo)      // Peer found but not paired
    case pairingInProgress(PeerInfo)    // Key exchange happening
    case connectionLost(reason: String) // Was connected, now lost
}
```

### State Transitions

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CONNECTION STATE MACHINE                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐  bonjour found  ┌───────────┐                    │
│  │ disconnected │────────────────→│ peerFound │                    │
│  └──────┬───────┘                 └─────┬─────┘                    │
│         │                               │                          │
│         │ start()           not paired? │ paired?                   │
│         ▼                      │        │                          │
│  ┌──────────────┐              ▼        ▼                          │
│  │ discovering  │    ┌─────────────┐  ┌───────────┐               │
│  └──────────────┘    │pairingReq'd │  │connecting │               │
│                      └──────┬──────┘  └─────┬─────┘               │
│                             │               │                      │
│                    accept   │               │ TCP established       │
│                             ▼               ▼                      │
│                      ┌────────────┐  ┌───────────┐                 │
│                      │pairingIn   │  │ connected │◄─── heartbeat   │
│                      │Progress    │  └─────┬─────┘     OK          │
│                      └──────┬─────┘        │                       │
│                             │              │ heartbeat timeout      │
│                    success  │              ▼                        │
│                             │       ┌──────────────┐               │
│                             └──────→│connectionLost│               │
│                                     └──────┬───────┘               │
│                                            │                       │
│                                   auto-retry (3x, backoff)         │
│                                            │                       │
│                                            ▼                       │
│                                     ┌──────────────┐               │
│                                     │ disconnected │               │
│                                     └──────────────┘               │
└─────────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                      SYNC STATE MACHINE (per SyncTarget)            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────┐   target enabled    ┌──────────┐                     │
│  │ disabled │ ──────────────────→ │  idle    │                     │
│  └──────────┘ ←────────────────── └────┬─────┘                     │
│      target disabled                   │                           │
│                                        │ peer connected             │
│                                        ▼                           │
│                                  ┌──────────┐                       │
│                                  │ watching │ ◄──── sync complete   │
│                                  └────┬─────┘       no conflicts    │
│                                       │                            │
│                          FSEvents  │  │  manual trigger             │
│                          (debounced)  │                             │
│                                       ▼                            │
│                                 ┌──────────┐                        │
│                        ┌───────│ syncing  │───────┐                │
│                        │       └──────────┘       │                │
│                        │              │           │                │
│                  conflict detected    │     rsync error             │
│                        │              │           │                │
│                        ▼              │           ▼                │
│                  ┌──────────┐         │    ┌──────────┐            │
│                  │ conflict │         │    │  error   │            │
│                  └────┬─────┘         │    └────┬─────┘            │
│                       │               │         │                  │
│              resolved │     success   │   retry (3x) │             │
│                       │               │         │                  │
│                       ▼               ▼         ▼                  │
│                  ┌──────────────────────────────────┐              │
│                  │          watching                 │              │
│                  └──────────────────────────────────┘              │
│                                                                     │
│  Pause trigger (network lost OR user action):                       │
│  Any state → paused                                                │
│  Resume: paused → watching                                          │
└─────────────────────────────────────────────────────────────────────┘
```

### Heartbeat Protocol

```swift
// Heartbeat sent every 15 seconds over NWConnection
// If 3 consecutive heartbeats missed (45s), transition to connectionLost

struct HeartbeatManager {
    let interval: Duration = .seconds(15)
    let missedThreshold: Int = 3
    
    private var missedCount: Int = 0
    private var lastReceived: ContinuousClock.Instant = .now
    
    mutating func heartbeatReceived() {
        missedCount = 0
        lastReceived = .now
    }
    
    mutating func tick() -> Bool {  // Returns false if connection considered lost
        if ContinuousClock.now - lastReceived > interval {
            missedCount += 1
        }
        return missedCount < missedThreshold
    }
}
```

---

## 9. Error Handling

### Error Taxonomy

```swift
enum SyncError: Error, Sendable, Equatable {
    // Network errors
    case peerUnreachable(hostname: String)
    case connectionTimeout(seconds: Int)
    case connectionRefused(port: UInt16)
    case bonjourResolutionFailed(serviceName: String)
    case networkInterfaceDown
    
    // SSH errors
    case sshKeyNotFound(path: String)
    case sshAuthFailed(hostname: String)
    case sshHostKeyChanged(hostname: String)
    case sshPermissionDenied(operation: String)
    case sshProcessCrashed(exitCode: Int32)
    
    // rsync errors
    case rsyncNotFound
    case rsyncPermissionDenied(path: String)
    case rsyncPartialTransfer(filesRemaining: Int)
    case rsyncIOError(path: String, errno: Int32)
    case rsyncProtocolMismatch(local: Int, remote: Int)
    case rsyncTimeout(seconds: Int)
    case rsyncVanished(path: String)  // File deleted during transfer
    
    // Disk errors
    case diskFull(availableBytes: Int64, requiredBytes: Int64)
    case diskQuotaExceeded
    case readOnlyFileSystem(path: String)
    case pathNotFound(path: String)
    case permissionDenied(path: String)
    
    // Application errors
    case conflictUnresolved(paths: [String])
    case targetDisabled(target: SyncTarget)
    case pairingRequired
    case protocolVersionMismatch(local: Int, remote: Int)
    case invalidState(expected: String, actual: String)
}
```

### Error Recovery Strategies

```swift
struct ErrorRecovery {
    struct Policy: Sendable {
        let maxRetries: Int
        let backoffStrategy: BackoffStrategy
        let recoveryAction: RecoveryAction
        let userNotification: NotificationLevel
    }
    
    enum BackoffStrategy: Sendable {
        case none
        case linear(baseMs: Int)           // baseMs * attempt
        case exponential(baseMs: Int)      // baseMs * 2^attempt
        case fixedDelay(ms: Int)
    }
    
    enum RecoveryAction: Sendable {
        case retry                         // Just retry the operation
        case retryWithFullSync             // Retry with full (not incremental) sync
        case reconnect                     // Re-establish SSH/NW connection first
        case repairSSH                     // Regenerate keys if corrupted
        case pauseAndNotify                // Stop syncing, alert user
        case disableTarget                 // Disable this sync target
        case fatal                         // Cannot recover; requires user intervention
    }
    
    enum NotificationLevel: Sendable {
        case silent                        // Log only
        case badge                         // Menu bar icon change
        case banner                        // macOS notification
        case alert                         // Modal alert (critical only)
    }
    
    static let policies: [SyncError: Policy] = [
        // Network: retry with exponential backoff
        .peerUnreachable(""): Policy(
            maxRetries: 5,
            backoffStrategy: .exponential(baseMs: 1000),
            recoveryAction: .reconnect,
            userNotification: .badge
        ),
        .connectionTimeout(0): Policy(
            maxRetries: 3,
            backoffStrategy: .exponential(baseMs: 2000),
            recoveryAction: .reconnect,
            userNotification: .badge
        ),
        
        // SSH: limited retry then notify
        .sshAuthFailed(""): Policy(
            maxRetries: 1,
            backoffStrategy: .none,
            recoveryAction: .repairSSH,
            userNotification: .banner
        ),
        .sshHostKeyChanged(""): Policy(
            maxRetries: 0,
            backoffStrategy: .none,
            recoveryAction: .fatal,
            userNotification: .alert
        ),
        
        // rsync: varies by type
        .rsyncPartialTransfer(0): Policy(
            maxRetries: 3,
            backoffStrategy: .linear(baseMs: 500),
            recoveryAction: .retry,
            userNotification: .silent
        ),
        .rsyncVanished(""): Policy(
            maxRetries: 1,
            backoffStrategy: .fixedDelay(ms: 1000),
            recoveryAction: .retryWithFullSync,
            userNotification: .silent
        ),
        
        // Disk: immediate notification
        .diskFull(0, 0): Policy(
            maxRetries: 0,
            backoffStrategy: .none,
            recoveryAction: .pauseAndNotify,
            userNotification: .alert
        ),
    ]
}
```

### Error Propagation Flow

```
rsync process exits with non-zero code
  │
  ├── FileSyncActor catches ProcessRunner error
  │     → Maps exit code to SyncError
  │     → Checks retry policy
  │     → If retries remaining: re-enqueue SyncJob with delay
  │     → If retries exhausted: emit SyncResult.failure(error)
  │
  ├── SyncCoordinator receives SyncResult.failure
  │     → Updates SyncStatus for target to .error(error)
  │     → Checks notification level
  │     → If .banner or .alert: schedules UserNotification
  │     → Logs to SyncHistory
  │
  └── UI observes SyncStatus change
        → Shows error indicator in menu bar
        → Shows error detail in target row
        → Offers "Retry" / "Ignore" / "View Details" actions
```

### rsync Exit Code Mapping

```swift
extension SyncError {
    init(rsyncExitCode: Int32, context: String) {
        switch rsyncExitCode {
        case 1:  self = .rsyncPermissionDenied(path: context)
        case 2:  self = .rsyncProtocolMismatch(local: 31, remote: 0)
        case 3:  self = .rsyncIOError(path: context, errno: 0)
        case 5:  self = .rsyncIOError(path: context, errno: 0)
        case 10: self = .connectionRefused(port: 22)
        case 11: self = .rsyncIOError(path: context, errno: 0)
        case 12: self = .rsyncIOError(path: context, errno: 0)
        case 14: self = .rsyncIOError(path: context, errno: 0)
        case 20: self = .rsyncPartialTransfer(filesRemaining: 0)
        case 23: self = .rsyncPartialTransfer(filesRemaining: 0)
        case 24: self = .rsyncVanished(path: context)
        case 25: self = .diskFull(availableBytes: 0, requiredBytes: 0)
        case 30: self = .rsyncTimeout(seconds: 30)
        case 35: self = .connectionTimeout(seconds: 10)
        case 255: self = .sshProcessCrashed(exitCode: rsyncExitCode)
        default: self = .rsyncIOError(path: context, errno: rsyncExitCode)
        }
    }
}
```

---

## 10. Security

### Threat Model

| Threat | Mitigation |
|--------|------------|
| Key compromise on one machine | Keys restricted to rsync-only via authorized_keys `command=` |
| Man-in-the-middle on LAN | SSH host key verification (accept-new on first connection, strict after) |
| Unauthorized pairing | Pairing requires explicit user acceptance on both machines |
| Credential exfiltration | Never sync `credentials.json`, `oauth_token*`, `.env.local` |
| Malicious rsync command injection | Peer cannot send arbitrary rsync flags; command built locally |
| Physical access to `~/.claudesync/ssh/` | File permissions: private key 0600, directory 0700 |

### SSH Key Management

```swift
actor SSHKeyManager {
    static let keyDirectory = URL(filePath: NSHomeDirectory())
        .appending(path: ".claudesync/ssh")
    static let privateKeyPath = keyDirectory.appending(path: "id_claudesync").path()
    static let publicKeyPath = keyDirectory.appending(path: "id_claudesync.pub").path()
    
    /// Generate new Ed25519 keypair for ClaudeSync
    func generateKeyPair() async throws {
        // Ensure directory exists with correct permissions
        try FileManager.default.createDirectory(
            at: Self.keyDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        
        let process = ProcessRunner(
            executable: "/usr/bin/ssh-keygen",
            arguments: [
                "-t", "ed25519",
                "-f", Self.privateKeyPath,
                "-N", "",                    // No passphrase
                "-C", "claudesync@\(Host.current().localizedName ?? "mac")",
            ]
        )
        
        let result = try await process.run()
        guard result.exitCode == 0 else {
            throw SSHKeyError.generationFailed(result.stderr)
        }
        
        // Enforce strict permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.privateKeyPath
        )
    }
    
    /// Read public key content
    func readPublicKey() throws -> String {
        try String(contentsOfFile: Self.publicKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// SHA256 fingerprint of public key
    func publicKeyFingerprint() async throws -> String {
        let process = ProcessRunner(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-lf", Self.publicKeyPath, "-E", "sha256"]
        )
        let result = try await process.runAndCapture()
        // Output: "256 SHA256:xxxx comment (ED25519)"
        return result.split(separator: " ")[1].description
    }
    
    /// Install peer's public key into authorized_keys with restrictions
    func installPeerKey(_ publicKey: String) throws {
        let authorizedKeysPath = NSHomeDirectory() + "/.ssh/authorized_keys"
        
        // Construct restricted entry
        let entry = """
        restrict,command="/usr/bin/rsync --server ${SSH_ORIGINAL_COMMAND#*--server }",\
        no-port-forwarding,no-X11-forwarding,no-agent-forwarding \
        \(publicKey)
        """
        
        // Ensure .ssh directory exists
        let sshDir = NSHomeDirectory() + "/.ssh"
        if !FileManager.default.fileExists(atPath: sshDir) {
            try FileManager.default.createDirectory(
                atPath: sshDir,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        
        // Append to authorized_keys
        let handle = try FileHandle(forWritingTo: URL(filePath: authorizedKeysPath))
        handle.seekToEndOfFile()
        handle.write(("\n" + entry + "\n").data(using: .utf8)!)
        handle.closeFile()
        
        // Ensure correct permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: authorizedKeysPath
        )
    }
    
    /// Remove peer's public key from authorized_keys
    func removePeerKey(fingerprint: String) throws {
        let authorizedKeysPath = NSHomeDirectory() + "/.ssh/authorized_keys"
        guard FileManager.default.fileExists(atPath: authorizedKeysPath) else { return }
        
        var lines = try String(contentsOfFile: authorizedKeysPath, encoding: .utf8)
            .components(separatedBy: .newlines)
        
        lines.removeAll { line in
            line.contains("claudesync@") && line.contains(fingerprint)
        }
        
        try lines.joined(separator: "\n")
            .write(toFile: authorizedKeysPath, atomically: true, encoding: .utf8)
    }
    
    /// Verify key pair exists and has correct permissions
    func verifyKeyIntegrity() throws -> KeyStatus {
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: Self.privateKeyPath) else {
            return .missing
        }
        
        let attrs = try fm.attributesOfItem(atPath: Self.privateKeyPath)
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        
        if perms != 0o600 {
            return .permissionsIncorrect(current: perms)
        }
        
        return .valid
    }
    
    enum KeyStatus {
        case valid
        case missing
        case permissionsIncorrect(current: Int)
        case corrupted
    }
}
```

### Data Protection Policies

```swift
struct SecurityPolicy {
    /// Files that must NEVER be synced under any configuration
    static let absolutelyExcluded: [String] = [
        "**/credentials.json",
        "**/oauth_token*",
        "**/.env.local",
        "**/.env.*.local",
        "**/id_rsa",
        "**/id_ed25519",
        "**/*.pem",
        "**/*.key",
        "**/keychain-*",
        "**/.netrc",
        "**/.npmrc",           // May contain auth tokens
        "**/.pypirc",          // May contain auth tokens
    ]
    
    /// These patterns are ALWAYS added to rsync excludes, regardless of user config
    static func enforceExclusions(in args: inout [String]) {
        for pattern in absolutelyExcluded {
            args += ["--exclude", pattern]
        }
    }
}
```

### Transport Security

All file data travels over SSH (encrypted with the session key negotiated during SSH handshake). The control channel (Bonjour TCP connection) carries only metadata (no file contents) and uses the custom NWProtocolFramer. Since control messages contain no sensitive data (only file paths, timestamps, sizes), TLS on the control channel is not required but can be added as a future enhancement.

```
Data plane:  rsync ──── SSH tunnel (AES-256-GCM / ChaCha20-Poly1305) ──── rsync
Control plane: NWConnection ──── TCP (plaintext JSON metadata) ──── NWConnection
```

---

## 11. Performance

### FSEvents Configuration

```swift
actor FileWatcherActor {
    private var streams: [SyncTarget: FSEventStreamRef] = [:]
    
    /// FSEvents configuration per target
    struct WatchConfig {
        let latency: CFTimeInterval       // Seconds before kernel coalesces events
        let flags: FSEventStreamCreateFlags
    }
    
    static let configs: [SyncTarget: WatchConfig] = [
        .claudeConfig: WatchConfig(
            latency: 0.3,                 // 300ms — fast response for config changes
            flags: [.useCFTypes, .fileEvents, .noDefer]
        ),
        .claudeAppSupport: WatchConfig(
            latency: 0.5,
            flags: [.useCFTypes, .fileEvents, .noDefer]
        ),
        .codexConfig: WatchConfig(
            latency: 0.3,
            flags: [.useCFTypes, .fileEvents, .noDefer]
        ),
        .projects: WatchConfig(
            latency: 1.0,                 // 1s — large tree, more coalescing
            flags: [.useCFTypes, .fileEvents, .noDefer, .ignoreSelf]
        ),
    ]
    
    func startWatching(target: SyncTarget, paths: [String]) {
        let config = Self.configs[target]!
        
        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(/* callback context */).toOpaque()
        
        let stream = FSEventStreamCreate(
            nil,                          // allocator
            fsEventsCallback,             // callback function
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            config.latency,
            config.flags.rawValue
        )!
        
        FSEventStreamSetDispatchQueue(stream, dispatchQueue)
        FSEventStreamStart(stream)
        streams[target] = stream
    }
}
```

### Debouncer Implementation

The debouncer uses a **2-second per-path quiet-period**: for each individual path, the timer resets every time a new event arrives for that path. rsync is only triggered when no new events have occurred for a given path within 2 seconds. This is distinct from a global debounce window -- each path has its own independent timer.

```swift
actor Debouncer {
    /// Per-path timers for quiet-period tracking
    private var pathTimers: [String: Task<Void, Never>] = [:]
    
    /// Accumulated paths ready to emit, grouped by target
    private var readyPaths: [SyncTarget: Set<String>] = [:]
    
    /// Flush timer: coalesce ready paths into a single emission
    private var flushTimer: Task<Void, Never>?
    
    private let output: AsyncStream<(SyncTarget, Set<String>)>.Continuation
    private let quietPeriod: Duration = .seconds(2)  // 2s per-path quiet-period
    
    /// Add paths for debouncing; resets the quiet-period timer for each individual path
    func addPaths(_ paths: Set<String>, for target: SyncTarget) {
        for path in paths {
            // Cancel existing timer for this specific path
            pathTimers[path]?.cancel()
            
            // Start new 2-second quiet-period timer for this path
            pathTimers[path] = Task { [weak self] in
                try? await Task.sleep(for: self?.quietPeriod ?? .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.markReady(path: path, target: target)
            }
        }
    }
    
    /// Path has completed its quiet-period; add to ready set
    private func markReady(path: String, target: SyncTarget) {
        pathTimers.removeValue(forKey: path)
        readyPaths[target, default: []].insert(path)
        
        // Schedule flush (small delay to coalesce paths completing simultaneously)
        if flushTimer == nil {
            flushTimer = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await flushReady()
            }
        }
    }
    
    private func flushReady() {
        let snapshot = readyPaths
        readyPaths.removeAll()
        flushTimer = nil
        for (target, paths) in snapshot where !paths.isEmpty {
            output.yield((target, paths))
        }
    }
    
    func cancelAll() {
        for timer in pathTimers.values { timer.cancel() }
        pathTimers.removeAll()
        flushTimer?.cancel()
        flushTimer = nil
        readyPaths.removeAll()
    }
}
```

### Memory Budget

| Component | Budget | Strategy |
|-----------|--------|----------|
| FSEvents buffers | 10 MB | Limited path string retention |
| Pending sync queue | 50 MB | Max 1000 queued SyncJobs; drop oldest low-priority |
| SyncHistory (SQLite) | 100 MB | Prune entries older than 30 days |
| SSH ControlMaster | 5 MB | Single socket per peer |
| Bonjour state | 1 MB | Single peer tracking |
| UI state | 5 MB | Virtualized lists, no full file tree in memory |
| **Total target** | **< 170 MB** | |

### rsync Performance Tuning

```swift
struct RsyncPerformanceConfig {
    /// Whether Homebrew GNU rsync is available (enables advanced flags)
    let isGNURsync: Bool
    
    /// Max concurrent rsync processes
    let maxConcurrent: Int = 3
    
    /// Band-width limit in KBps (0 = unlimited)
    let bwLimit: Int = 0         // No limit on LAN
    
    /// Block size for delta algorithm (larger = less CPU, more bandwidth)
    /// Default 700 bytes; increase for large binary files
    /// NOTE: only supported by GNU rsync
    let blockSize: Int? = nil    // Use rsync default
    
    func additionalArgs() -> [String] {
        var args: [String] = []
        
        if bwLimit > 0 {
            args += ["--bwlimit=\(bwLimit)"]
        }
        
        // GNU rsync-only optimizations (not available in macOS openrsync)
        if isGNURsync {
            args += ["--compress-choice=none"]         // LAN: skip compression overhead
            args += ["--checksum-choice=xxhash"]       // Faster than MD5
            if let blockSize {
                args += ["-B", "\(blockSize)"]
            }
        }
        
        return args
    }
}
```

**Note on macOS openrsync**: The system rsync on macOS Sequoia is `openrsync` which does not support `--compress-choice`, `--checksum-choice`, `--log-file`, `-E`, or `--backup-dir`. The `RsyncCommandBuilder` auto-detects which binary is available and uses only the safe flag set with openrsync. If users install Homebrew rsync 3.x (`brew install rsync`), the full feature set becomes available automatically.

### Sync Scheduling and Prioritization

```swift
actor FileSyncActor {
    /// Priority queue: critical > high > normal > low > background
    private var queue: PriorityQueue<SyncJob> = PriorityQueue()
    
    /// Max concurrent rsync processes
    private let maxConcurrent = 3
    private var runningJobs: [UUID: Task<SyncResult, Error>] = [:]
    
    func enqueue(_ job: SyncJob) {
        // Deduplicate: if same target + direction already queued, merge paths
        if let existing = queue.first(where: { $0.target == job.target && $0.direction == job.direction }) {
            existing.paths.formUnion(job.paths)
            return
        }
        
        queue.insert(job)
        scheduleNext()
    }
    
    private func scheduleNext() {
        while runningJobs.count < maxConcurrent, let job = queue.dequeue() {
            runningJobs[job.id] = Task {
                defer { runningJobs.removeValue(forKey: job.id) }
                let result = try await executeSync(job)
                scheduleNext()
                return result
            }
        }
    }
}
```

### Disk Space Monitoring

```swift
struct DiskSpaceMonitor {
    /// Minimum free space required to proceed with sync (500 MB)
    static let minimumFreeSpace: Int64 = 500 * 1024 * 1024
    
    /// Check before starting any sync
    func checkAvailableSpace(at path: String) throws {
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: path
        )
        let freeSpace = attrs[.systemFreeSize] as? Int64 ?? 0
        
        if freeSpace < Self.minimumFreeSpace {
            throw SyncError.diskFull(
                availableBytes: freeSpace,
                requiredBytes: Self.minimumFreeSpace
            )
        }
    }
}
```

---

## 12. Key Type Signatures

### Core Coordinator

```swift
@MainActor
final class SyncCoordinator: ObservableObject {
    // Published state
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var syncStatuses: [SyncTarget: SyncStatus] = [:]
    @Published private(set) var lastSyncTimes: [SyncTarget: Date] = [:]
    @Published private(set) var pendingConflicts: [ConflictNotification] = []
    @Published private(set) var recentActivity: [SyncActivityItem] = []
    
    // Dependencies
    private let peerDiscovery: PeerDiscoveryActor
    private let fileWatcher: FileWatcherActor
    private let fileSync: FileSyncActor
    private let conflictResolver: ConflictResolver
    private let appState: AppState
    private let syncHistory: SyncHistory
    
    // Lifecycle
    func start() async
    func stop() async
    
    // User actions
    func enableTarget(_ target: SyncTarget) async
    func disableTarget(_ target: SyncTarget) async
    func triggerFullSync(for target: SyncTarget) async
    func pauseAllSync() async
    func resumeAllSync() async
    func resolveConflict(_ conflict: ConflictNotification, with resolution: ConflictResolver.Resolution) async
    func unpairPeer() async
    func acceptPairing(from peer: PeerInfo) async
    func rejectPairing(from peer: PeerInfo) async
}
```

### Peer Discovery

```swift
actor PeerDiscoveryActor {
    // State
    private(set) var discoveredPeers: [UUID: PeerInfo] = [:]
    private(set) var connectedPeer: PeerInfo?
    
    // Control
    func startDiscovery() async
    func stopDiscovery() async
    func connect(to peer: PeerInfo) async throws
    func disconnect() async
    func send(_ message: ControlMessage) async throws
    
    // Event stream for coordinator
    var events: AsyncStream<PeerEvent> { get }
}

enum PeerEvent: Sendable {
    case peerAppeared(PeerInfo)
    case peerDisappeared(UUID)
    case peerConnected(PeerInfo)
    case peerDisconnected(UUID, reason: String)
    case messageReceived(ControlMessage)
    case heartbeatMissed(count: Int)
}
```

### Peer Info

```swift
struct PeerInfo: Identifiable, Codable, Sendable, Equatable {
    let id: UUID                     // machineId
    let hostname: String
    let username: String
    let sshPort: UInt16
    let publicKeyFingerprint: String
    var endpoint: NWEndpoint?        // Resolved network endpoint (not Codable)
    var lastSeen: Date
    var isPaired: Bool
    
    var sshAddress: String {
        "\(username)@\(resolvedHostname)"
    }
    
    var resolvedHostname: String {
        // Prefer .local hostname for Bonjour resolution
        "\(hostname).local"
    }
}
```

### Sync Job and Result

```swift
struct SyncJob: Identifiable, Sendable, Comparable {
    let id: UUID
    let target: SyncTarget
    var paths: Set<String>           // Empty = full sync of target
    let direction: SyncDirection
    let priority: SyncPriority
    let createdAt: ContinuousClock.Instant
    let isFullSync: Bool
    var retryCount: Int = 0
    
    static func < (lhs: SyncJob, rhs: SyncJob) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority  // Lower raw value = higher priority
        }
        return lhs.createdAt < rhs.createdAt    // FIFO within same priority
    }
}

enum SyncDirection: String, Codable, Sendable {
    case push    // Local → Remote
    case pull    // Remote → Local
}

struct SyncResult: Sendable {
    let jobId: UUID
    let target: SyncTarget
    let status: ResultStatus
    let filesTransferred: Int
    let bytesTransferred: Int64
    let duration: Duration
    let conflicts: [ConflictInfo]
    let errors: [SyncError]
    
    enum ResultStatus: Sendable {
        case success
        case partialSuccess(transferredCount: Int, failedCount: Int)
        case failure(SyncError)
        case cancelled
    }
}
```

### File Watcher

```swift
actor FileWatcherActor {
    /// Start watching all enabled targets
    func startWatching(targets: [SyncTarget]) async
    
    /// Stop watching a specific target
    func stopWatching(target: SyncTarget) async
    
    /// Stop all watches
    func stopAll() async
    
    /// Register rsync process writing to paths (echo suppression keyed to PID lifecycle)
    func registerRsyncProcess(pid: pid_t, for paths: Set<String>) async
    
    /// Unregister rsync process on exit (releases suppression after 1s buffer)
    func unregisterRsyncProcess(pid: pid_t, for paths: Set<String>) async
    
    /// On startup: clean stale suppression markers from previous crashes
    func cleanupStaleMarkers() async
    
    /// Output stream of debounced file change events
    var changes: AsyncStream<(SyncTarget, Set<String>)> { get }
}

struct WatchedPath: Hashable, Sendable {
    let absolutePath: String
    let target: SyncTarget
    let eventFlags: FSEventStreamEventFlags
    let eventTime: Date
}
```

### Persistence

```swift
@MainActor
final class AppState: ObservableObject, Codable {
    @Published var machineId: UUID
    @Published var pairedPeer: PeerInfo?
    @Published var enabledTargets: Set<SyncTarget>
    @Published var targetConfigs: [SyncTarget: TargetConfig]
    @Published var conflictStrategy: ConflictResolver.Strategy
    @Published var launchAtLogin: Bool
    @Published var showInDock: Bool
    @Published var syncOnWake: Bool
    
    struct TargetConfig: Codable {
        var isEnabled: Bool
        var syncMode: SyncMode
        var customExcludes: [String]
        var debounceOverrideMs: Int?
    }
    
    /// Persists to ~/.claudesync/config.json
    func save() throws
    static func load() throws -> AppState
}

actor SyncHistory {
    /// SQLite database at ~/.claudesync/history.sqlite
    
    func recordSync(_ result: SyncResult) async throws
    func lastSyncTime(for target: SyncTarget) async -> Date?
    func lastSyncedVersion(of path: String) async -> FileVersion?
    func recentActivity(limit: Int) async -> [SyncActivityItem]
    func pruneOlderThan(_ date: Date) async throws
    func totalBytesTransferred(since: Date) async -> Int64
}

struct SyncActivityItem: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let target: SyncTarget
    let direction: SyncDirection
    let filesCount: Int
    let bytesCount: Int64
    let status: SyncResult.ResultStatus
}
```

### Utilities

```swift
actor ProcessRunner {
    let executable: String
    let arguments: [String]
    let environment: [String: String]?
    let workingDirectory: URL?
    
    struct Output: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        
        var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
    }
    
    /// Run process and wait for completion
    func run() async throws -> Output
    
    /// Run process and stream stdout line by line
    func runStreaming() -> AsyncThrowingStream<String, Error>
    
    /// Cancel running process
    func cancel()
}

struct Logger {
    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        case critical = 4
    }
    
    static let shared = Logger()
    
    func log(_ message: String, level: Level, category: String)
    func debug(_ message: String, category: String = "general")
    func info(_ message: String, category: String = "general")
    func warning(_ message: String, category: String = "general")
    func error(_ message: String, category: String = "general")
    
    /// Categories: "sync", "discovery", "ssh", "watcher", "ui", "general"
}

actor Debouncer {
    init(output: AsyncStream<(SyncTarget, Set<String>)>.Continuation)
    func addPaths(_ paths: Set<String>, for target: SyncTarget)
    func flush(target: SyncTarget)
    func cancelAll()
}
```

### Ignore Patterns

```swift
struct IgnorePatterns: Sendable {
    /// Global excludes that apply to ALL targets
    let globalExcludes: [String]
    
    /// Per-target excludes from SyncTarget.spec
    let targetExcludes: [SyncTarget: [String]]
    
    /// User-configured additional excludes from AppState
    let userExcludes: [SyncTarget: [String]]
    
    /// Per-project .claudesyncignore files (projects target only)
    let projectIgnores: [String: [String]]  // projectPath -> patterns
    
    /// Security-enforced excludes (cannot be overridden)
    let securityExcludes: [String]  // = SecurityPolicy.absolutelyExcluded
    
    /// Check if a path should be excluded from sync
    func shouldExclude(path: String, target: SyncTarget) -> Bool
    
    /// Build rsync --exclude arguments for a job
    func rsyncExcludeArgs(for target: SyncTarget, projectPath: String?) -> [String]
    
    /// Parse .claudesyncignore file (gitignore syntax)
    static func parseIgnoreFile(at url: URL) throws -> [String]
}
```

### Package Sync

```swift
actor BrewSyncManager {
    struct BrewPackage: Hashable, Codable, Sendable {
        let name: String
        let fullName: String       // tap/name or just name
        let version: String?
        let type: PackageType      // formula, cask
        
        enum PackageType: String, Codable, Sendable {
            case formula
            case cask
            case tap
        }
    }
    
    struct BrewDiff: Sendable {
        let missingLocally: Set<BrewPackage>
        let missingRemotely: Set<BrewPackage>
        let versionDifferences: [(package: String, local: String, remote: String)]
    }
    
    func generateBrewfile() async throws -> URL
    func parseBrewfile(at url: URL) throws -> Set<BrewPackage>
    func diff(local: URL, remote: URL) async throws -> BrewDiff
    func installMissing(_ packages: Set<BrewPackage>) async throws
}

actor NpmGlobalSyncManager {
    struct NpmPackage: Hashable, Codable, Sendable {
        let name: String
        let version: String
    }
    
    struct NpmDiff: Sendable {
        let missingLocally: [NpmPackage]
        let missingRemotely: [NpmPackage]
        let versionDifferences: [(package: String, local: String, remote: String)]
    }
    
    func listGlobals() async throws -> [NpmPackage]
    func diff(local: [NpmPackage], remote: [NpmPackage]) -> NpmDiff
    func installMissing(_ packages: [NpmPackage]) async throws
}
```

---

## Appendix A: File Permissions Summary

| Path | Owner | Permissions | Notes |
|------|-------|-------------|-------|
| `~/.claudesync/` | user | 0700 | App state directory |
| `~/.claudesync/ssh/` | user | 0700 | SSH key directory |
| `~/.claudesync/ssh/id_claudesync` | user | 0600 | Private key |
| `~/.claudesync/ssh/id_claudesync.pub` | user | 0644 | Public key |
| `~/.claudesync/config.json` | user | 0644 | App configuration |
| `~/.claudesync/history.sqlite` | user | 0644 | Sync history DB |
| `~/.ssh/authorized_keys` | user | 0600 | Modified during pairing |

## Appendix B: System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| macOS Version | 14.0 (Sonoma) | 15.0+ (Sequoia) |
| rsync | openrsync (system, macOS 15+) or rsync 2.6.9 (macOS 14) | Homebrew rsync 3.2.7+ (`brew install rsync`) for full feature set |
| SSH | OpenSSH 9.0+ | System default |
| Remote Login | Enabled (System Settings > General > Sharing > Remote Login) | Required on both machines |
| Full Disk Access | Required for FSEvents on ~/Documents, ~/Library | Grant on first launch |
| Disk Space | 500 MB free | 5 GB free |
| Network | LAN (any speed) | Gigabit Ethernet or WiFi 6 |
| RAM | System (no special requirement) | — |

## Appendix C: Configuration File Formats

### ~/.claudesync/config.json

```json
{
  "machineId": "550e8400-e29b-41d4-a716-446655440000",
  "pairedPeer": {
    "id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "hostname": "iMac",
    "username": "kim",
    "sshPort": 22,
    "publicKeyFingerprint": "SHA256:abcdef...",
    "lastSeen": "2026-05-03T10:30:00Z",
    "isPaired": true
  },
  "enabledTargets": ["claudeConfig", "claudeAppSupport", "codexConfig", "projects"],
  "targetConfigs": {
    "claudeConfig": {
      "isEnabled": true,
      "syncMode": "bidirectional",
      "customExcludes": [],
      "debounceOverrideMs": null
    },
    "projects": {
      "isEnabled": true,
      "syncMode": "bidirectional",
      "customExcludes": ["large-ml-models/"],
      "debounceOverrideMs": 2000
    }
  },
  "conflictStrategy": "newerWins",
  "launchAtLogin": true,
  "showInDock": false,
  "syncOnWake": true
}
```

### ~/.claudesync/brew/Brewfile (generated)

```ruby
tap "homebrew/core"
tap "homebrew/cask"
brew "node"
brew "go"
brew "python@3.12"
brew "ripgrep"
brew "fd"
cask "visual-studio-code"
cask "iterm2"
```

## Appendix D: Timing Constants

| Constant | Value | Rationale |
|----------|-------|-----------|
| FSEvents latency (config) | 300ms | Fast kernel-level coalescing for small config files |
| FSEvents latency (projects) | 1000ms | Reduce noise for large file trees |
| Debounce (Tier 1: real-time) | 2s per-path quiet-period | No new events for 2s before rsync fires. Balances responsiveness with preventing rapid-fire syncs during IDE autosave. Combined with <1s rsync for small files, stays within 3s sync target. |
| Debounce (Tier 2: batched) | 5 min accumulation | Sessions/transcripts are append-only; batch reduces rsync invocations |
| Debounce (Tier 3: on-demand) | N/A (manual/scheduled) | Large trees sync on trigger only |
| Echo suppression | rsync PID lifecycle + 1s buffer | Suppression duration matches actual write time; released on process exit + 1s for filesystem journal flush |
| Heartbeat interval | 15s | Detect disconnection within 45s |
| Heartbeat timeout | 45s (3 missed) | Balance detection speed vs. false positives |
| SSH ControlPersist | 300s (5min) | Keep connection warm between syncs |
| SSH ConnectTimeout | 10s | Fast failure on unreachable peer |
| rsync I/O timeout | 30s | Detect stalled transfers |
| rsync connection timeout | 10s | Fast failure on unreachable peer (GNU rsync only) |
| Retry backoff base | 1000ms | Exponential: 1s, 2s, 4s, 8s, 16s |
| Max retry count (network) | 5 | Give up after ~31s total |
| Max retry count (rsync) | 3 | Give up after ~7s total |
| History pruning age | 30 days | Keep database manageable |
| Disk space check interval | Before each sync | Never start sync without space |
| Minimum free disk space | 500 MB | Safety margin |

---

*End of Technical Specification*
