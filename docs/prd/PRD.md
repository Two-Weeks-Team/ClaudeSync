# Product Requirements Document: ClaudeSync

**Version**: 1.0  
**Date**: 2026-05-03  
**Author**: Product Team  
**Status**: Draft  

---

## Table of Contents

1. [Overview](#1-overview)
2. [Problem Statement](#2-problem-statement)
3. [Goals & Non-Goals](#3-goals--non-goals)
4. [User Stories](#4-user-stories)
5. [Functional Requirements](#5-functional-requirements)
6. [Non-Functional Requirements](#6-non-functional-requirements)
7. [Technical Architecture Summary](#7-technical-architecture-summary)
8. [Risks & Mitigations](#8-risks--mitigations)
9. [Success Metrics](#9-success-metrics)
10. [Timeline](#10-timeline)

---

## 1. Overview

**ClaudeSync** is a native macOS menu bar application that continuously synchronizes AI coding tool environments between two Macs. The app runs as a persistent background service, auto-discovers paired machines on the same local network via Bonjour/mDNS, and keeps all relevant configuration files, sessions, memory, and project data in sync with near-zero latency.

The product targets developers who split their work across multiple Apple machines (e.g., MacBook Pro at a desk and MacBook Air on the go) and use AI-assisted coding tools such as Claude Code CLI, Claude Desktop, and Codex CLI. ClaudeSync eliminates the "configuration drift" problem where skills, hooks, MCP server configs, memory, sessions, and installed packages diverge between machines.

### Product Principles

- **Invisible by default** — The app should require zero daily interaction once paired. It runs in the menu bar and just works.
- **Safety over speed** — Never lose user data. Conflicts must be preserved, not silently overwritten.
- **Native performance** — Pure Swift, no Electron, no external runtime dependencies. Low resource footprint.
- **Privacy first** — All sync happens over the local network via SSH. No cloud relay, no accounts, no telemetry.

---

## 2. Problem Statement

### Current Pain Points

Developers using AI coding tools across multiple Macs face compounding frustration:

1. **Configuration Drift** — Claude Code's `~/.claude/` directory contains settings, custom skills, hooks, slash commands, memory, and session transcripts. Changes made on one machine do not propagate to the other, leading to inconsistent behavior and lost productivity.

2. **Manual Sync Overhead** — Developers resort to manual rsync scripts, git repos for dotfiles, or cloud storage mounts. These solutions are fragile, require constant attention, and often miss critical directories.

3. **MCP Server Config Divergence** — Claude Desktop stores MCP server configurations in `~/Library/Application Support/Claude/`. Installing or configuring an MCP server on one machine means manually replicating the setup on the other.

4. **Session and Memory Loss** — AI coding sessions accumulate context (memory, project knowledge, conversation history). Switching machines means starting from scratch or manually transferring session state.

5. **Package Drift** — Homebrew formulae, npm global packages, and CLI tools diverge between machines. A workflow that works on one machine fails on the other due to missing dependencies.

6. **Project File Staleness** — Active project files in `~/Documents/GitHub/` may be hours or days behind on the secondary machine, requiring full git pulls and dependency reinstalls before resuming work.

### Impact

- 15-30 minutes lost per machine switch for manual environment reconciliation
- Broken workflows due to missing packages or stale configs
- Cognitive overhead of tracking which machine has the "current" state
- Risk of data loss when changes are made on both machines

---

## 3. Goals & Non-Goals

### Goals

| # | Goal | Measurement |
|---|------|-------------|
| G1 | Eliminate configuration drift for AI coding tools between two Macs | Zero manual sync actions needed after initial pairing |
| G2 | Achieve near-real-time sync (<3s latency) for config changes | P95 sync latency under 3 seconds |
| G3 | Zero data loss guarantee | No user files overwritten without recovery option |
| G4 | Minimal resource usage suitable for always-on operation | <50MB RAM, <1% CPU when idle |
| G5 | Zero-configuration networking (no IP addresses, no port forwarding) | Bonjour auto-discovery on same network |
| G6 | One-time setup under 2 minutes | First pairing completed in 3 clicks or fewer |

### Non-Goals

- **Cloud sync** — This is a local-network-only tool. No cloud relay service.
- **Three or more machines** — V1 supports exactly two machines (1:1 pairing).
- **Cross-platform** — macOS only. No Windows or Linux support.
- **Real-time collaborative editing** — This is not a CRDT-based collaboration tool.
- **Backup solution** — ClaudeSync is sync, not backup. Users should maintain their own backups.
- **Mac App Store distribution** — Requires unsandboxed access to rsync, SSH, and FSEvents.

---

## 4. User Stories

### Prerequisites & Setup

| ID | Story | Acceptance Criteria |
|----|-------|-------------------|
| US-00 | As a developer, I want ClaudeSync to verify that Remote Login (SSH) is enabled on both machines before pairing, so I get a clear error instead of a cryptic failure. | Preflight check tests SSH connectivity; if sshd is not responding, shows error message with explanation and deep-link to System Settings > General > Sharing > Remote Login. |
| US-01 | As a developer, I want to install ClaudeSync on both Macs and have them find each other automatically so I don't need to configure network settings. | App discovers peer within 5 seconds on same WiFi; no IP entry required. |
| US-02 | As a developer, I want one-click pairing that sets up SSH keys so I never need to enter passwords for sync. | Ed25519 keypair generated and exchanged; subsequent connections are passwordless. |
| US-03 | As a developer, I want to see which Mac is the "source of truth" during initial sync so I can confirm the direction before data transfers. | Initial sync shows a confirmation dialog with file counts and direction arrow. |

### Daily Usage

| ID | Story | Acceptance Criteria |
|----|-------|-------------------|
| US-04 | As a developer, I want changes to my Claude Code skills/hooks to appear on my other Mac within seconds so both machines behave identically. | File change on Machine A is reflected on Machine B within 3 seconds. |
| US-05 | As a developer, I want the menu bar icon to clearly show sync status so I know at a glance if everything is healthy. | Green = synced, Yellow = syncing, Red = error/disconnected. |
| US-06 | As a developer, I want my Claude Desktop MCP server configs to sync so newly installed MCP servers work on both machines. | `claude_desktop_config.json` changes propagate bidirectionally. |
| US-07 | As a developer, I want node_modules and build artifacts excluded automatically so sync is fast and doesn't waste bandwidth. | Default ignore list prevents syncing of `node_modules/`, `.next/`, `dist/`, `build/`, `cache/`, `tmp/`. |
| US-08 | As a developer, I want to see sync history so I can verify what changed and when. | Last 100 sync events visible in the app with timestamp, file path, and direction. |

### Conflict Handling

| ID | Story | Acceptance Criteria |
|----|-------|-------------------|
| US-09 | As a developer, I want the newer file to win in conflicts so I don't need to manually resolve most situations. | Newer mtime wins; older version archived to `~/.claudesync/conflicts/`. |
| US-10 | As a developer, I want same-timestamp conflicts preserved so I can manually choose which version to keep. | Both versions saved with `.machine-a` and `.machine-b` suffixes. |

### Package Management

| ID | Story | Acceptance Criteria |
|----|-------|-------------------|
| US-11 | As a developer, I want to see which brew/npm packages differ between my machines so I can keep them aligned. | Environment diff view shows package name, version on each machine, and install action. |
| US-12 | As a developer, I want one-click package installation for missing packages so I can resolve drift quickly. | "Install All Missing" button runs appropriate package manager commands. |

### Advanced

| ID | Story | Acceptance Criteria |
|----|-------|-------------------|
| US-13 | As a developer, I want to toggle individual sync targets on/off so I can control what syncs. | Checkboxes for each sync target (Claude Code, Claude Desktop, Codex, Projects, Packages). |
| US-14 | As a developer, I want to throttle sync bandwidth so large project syncs don't saturate my network. | Bandwidth slider from 1 MB/s to unlimited. |

---

## 5. Functional Requirements

### P0 — Must Have (MVP)

#### FR-00: Remote Login (sshd) Prerequisite Check

- **Description**: Both machines MUST have Remote Login enabled (System Settings > General > Sharing > Remote Login). ClaudeSync performs a preflight check before completing the pairing flow.
- **Behavior**:
  - On pairing initiation, test SSH connectivity to the discovered peer by attempting `ssh -o BatchMode=yes -o ConnectTimeout=5 <peer> "echo ok"`.
  - If sshd is not responding, display a clear error: "Remote Login is not enabled on [peer hostname]. Please enable it in System Settings > General > Sharing > Remote Login."
  - Provide a "Open System Settings" button that deep-links to `x-apple.systempreferences:com.apple.preferences.sharing`.
  - Do not proceed with key exchange until SSH connectivity is confirmed on both sides.
  - If the local machine's sshd is also not running, show the same guidance for the local machine first.
- **Rationale**: Without Remote Login enabled, rsync-over-SSH will silently fail. This is the most common first-time setup failure and must be caught early with an actionable message.

#### FR-00b: Full Disk Access Permission Flow

- **Description**: On first launch, check Full Disk Access (FDA) status. FSEvents registration on protected paths (e.g., `~/Documents/`, `~/Library/`) requires FDA.
- **Behavior**:
  - On first launch, check FDA status via a canary file access test on a protected path.
  - If FDA is not granted, show an onboarding step explaining why it is needed: "ClaudeSync needs Full Disk Access to monitor file changes in your Documents and Library folders."
  - Provide a direct link to Privacy & Security settings: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  - Do NOT attempt FSEvents stream registration until FDA is confirmed.
  - Re-check FDA status on each app launch; if revoked, pause all file watching and show the onboarding step again.
- **Rationale**: Without FDA, FSEvents will not fire for protected directories, resulting in silent sync failures.

#### FR-01: Menu Bar Tray Application

- **Description**: Native macOS menu bar app that runs persistently in the background.
- **Behavior**:
  - App launches at login (configurable).
  - Menu bar icon reflects current sync state:
    - Green circle: All synced, peer connected.
    - Yellow circle: Sync in progress.
    - Red circle: Error or peer disconnected.
  - Clicking the icon shows a popover with sync status summary.
  - "Quit" option in the menu.
- **Technical**: SwiftUI `MenuBarExtra` with `isInserted` binding.

#### FR-02: Auto-Discovery via Bonjour

- **Description**: Automatically discover the paired Mac on the local network without manual configuration.
- **Behavior**:
  - On launch, advertise service as `_claudesync._tcp` on the local domain.
  - Simultaneously browse for other instances of the same service type.
  - When peer discovered, establish control channel connection.
  - When peer disappears (leaves network), update status to disconnected (red icon).
  - Re-establish connection automatically when peer reappears.
- **Technical**: `NWBrowser` and `NWListener` from Network.framework.

#### FR-03: One-Click Pairing

- **Description**: First-time setup that establishes a secure, passwordless SSH connection between the two machines.
- **Behavior**:
  - On first discovery of unpaired peer, show pairing request dialog on both machines.
  - Generate Ed25519 SSH keypair at `~/.claudesync/ssh/id_ed25519`.
  - Exchange public keys over the Bonjour control channel (secured by visual confirmation code).
  - Install peer's public key in `~/.ssh/authorized_keys`.
  - Verify connection by performing a test rsync.
  - Store pairing metadata in `~/.claudesync/config.json`.
- **Security**: 6-digit visual confirmation code displayed on both screens must match before key exchange proceeds.

#### FR-04: Always-On File Sync Engine

- **Description**: Continuously monitor specified directories for changes and sync them to the peer.
- **Behavior**:
  - Use FSEvents to watch configured directories.
  - On file change detection (create/modify/delete), queue sync operation.
  - Debounce rapid changes using a **2-second per-path quiet-period** (no new FSEvents for a given path within 2 seconds before triggering rsync). This prevents rapid-fire syncs during saves, builds, and IDE autosave while keeping latency acceptable for the <3s sync target.
  - Execute rsync over SSH with the following safe flag set (compatible with macOS Sequoia's openrsync):
    - `--archive --compress --delete --update --itemize-changes -e ssh`
    - `--partial --timeout=30`
    - `--exclude-from=~/.claudesync/ignore`
  - Report sync completion via control channel.
  - Handle deletions: propagate file/directory deletions to peer.
- **Sync Loop Prevention**:
  - Echo suppression is keyed to the rsync process lifecycle, NOT a fixed timer.
  - Track active rsync PIDs per destination path. While an rsync process is writing to a path, suppress FSEvents for that path.
  - Release suppression on rsync process exit + 1-second buffer (to allow filesystem journal flush).
  - On app startup, scan for and remove any stale suppression markers left by a previous crash (e.g., orphaned `.claudesync/.syncing-<pid>` files where the PID is no longer running).
- **Technical**: `FSEventStreamCreate` with `kFSEventStreamCreateFlagFileEvents`.

#### FR-04b: 3-Tier Sync Architecture

- **Description**: Different file types have different sync urgency and volume characteristics. ClaudeSync uses a tiered approach to optimize latency for critical files while avoiding bandwidth saturation from large append-only data.
- **Tiers**:
  - **Tier 1 — Real-time (<3s latency)**: `settings.json`, `CLAUDE.md`, `hooks/`, `commands/`, `memory/`, `claude_desktop_config.json`, `~/.codex/` config files. These are small files where changes must propagate immediately.
  - **Tier 2 — Batched (5-minute intervals)**: `sessions/`, `transcripts/`. These are append-only, large files that accumulate over time. Syncing them in 5-minute batches reduces rsync invocations and network overhead without impacting the user experience.
  - **Tier 3 — On-demand/Scheduled**: `~/Documents/GitHub/`, brew/npm package lists. These sync on explicit user trigger, on a configurable schedule (default: 30 minutes for packages), or on wake-from-sleep.
- **Behavior**:
  - Each tier has its own debounce window and scheduling logic.
  - Tier 1 uses the standard 2-second per-path debounce.
  - Tier 2 accumulates changes and flushes every 5 minutes (or on app quit/sleep).
  - Tier 3 syncs only when triggered (user action, schedule, or wake event).
  - Priority queue ensures Tier 1 jobs always execute before Tier 2 or 3.

#### FR-05: Claude Code Directory Sync

- **Description**: Full bidirectional sync of `~/.claude/` directory.
- **Scope** (all subdirectories and files):
  - `settings.json` — Global and project-specific settings
  - `CLAUDE.md` — User instructions
  - `commands/` — Custom slash commands
  - `skills/` — Installed skills
  - `hooks/` — Configured hooks
  - `memory/` — Project and global memory
  - `sessions/` — Session transcripts and state
  - `todos/` — Task management state
  - `statsig/` — Feature flags cache
  - `projects/` — Project-specific configs
- **Size expectation**: ~3GB total (sessions and transcripts dominate).
- **Special handling**: Lock files (`.lock`) are excluded from sync.

#### FR-06: Claude Desktop Configuration Sync

- **Description**: Sync Claude Desktop application configuration.
- **Scope**: `~/Library/Application Support/Claude/`
  - `claude_desktop_config.json` — MCP server configurations
  - `preferences.json` — App preferences
- **Special handling**: Restart notification if MCP config changes (Claude Desktop must be restarted to pick up new MCP servers).

#### FR-07: Codex CLI Configuration Sync

- **Description**: Sync OpenAI Codex CLI configuration.
- **Scope**: `~/.codex/`
  - Configuration files
  - Custom instructions
- **Size expectation**: <10MB.

#### FR-08: Smart Ignore Rules

- **Description**: Exclude unnecessary files and directories from sync to preserve bandwidth and storage.
- **Default ignore patterns**:
  ```
  node_modules/
  .next/
  dist/
  build/
  .build/
  cache/
  .cache/
  tmp/
  .tmp/
  *.log
  .DS_Store
  .git/objects/
  .git/pack/
  *.lock
  ```
- **Customization**: Users can add patterns to `~/.claudesync/ignore`.
- **Behavior**: Patterns follow rsync exclude syntax.

#### FR-09: Conflict Resolution

- **Description**: Handle file conflicts when both machines modify the same file.
- **Rules**:
  1. **Newer wins**: File with later `mtime` overwrites the older version.
  2. **Archive loser**: The overwritten version is saved to `~/.claudesync/conflicts/[date]/[path]`.
  3. **Same-timestamp tie**: Both versions preserved with machine-name suffixes; user notified.
  4. **Conflict notification**: Yellow badge on menu bar icon; details in sync history.
- **Retention**: Conflict archive auto-purged after 30 days.

---

### P1 — Should Have

#### FR-10: Package Sync & Diff

- **Description**: Detect and reconcile package differences between machines.
- **Behavior**:
  - Periodically (every 30 minutes) collect installed package lists:
    - `brew list --formula` and `brew list --cask`
    - `npm list -g --depth=0`
  - Compare lists between machines.
  - Display diff in Environment Diff view.
  - Offer "Install Missing" action for individual or batch installation.
- **Limitations**: Does not sync package versions automatically (only presence/absence).

#### FR-11: Project Folder Sync

- **Description**: Sync project working directories.
- **Scope**: `~/Documents/GitHub/` (configurable path).
- **Size handling**: Expected ~67GB with excludes applied.
- **Behavior**:
  - Uses same FSEvents + rsync pipeline as config sync.
  - Smart ignore rules aggressively filter build artifacts.
  - Initial sync may take significant time; progress bar shown.
  - Subsequent syncs are incremental (only changed files).
- **Opt-in**: Disabled by default; user must explicitly enable.

#### FR-12: Environment Diff View

- **Description**: Visual comparison of the two machines' environments.
- **Display**:
  - Side-by-side view of sync targets with file counts and sizes.
  - Package comparison table (name, version Machine A, version Machine B).
  - Last sync time per target.
  - Pending changes count.

#### FR-13: Sync History Log

- **Description**: Persistent log of recent sync events for auditability.
- **Behavior**:
  - Store last 100 sync events in `~/.claudesync/history.json`.
  - Each entry contains: timestamp, file path, direction (A->B or B->A), action (create/modify/delete), size.
  - Viewable in app popover under "History" tab.
  - Exportable as JSON.

---

### P2 — Nice to Have

#### FR-14: Selective Sync Toggles

- **Description**: Allow users to enable/disable individual sync targets.
- **Behavior**:
  - Toggle switches for: Claude Code, Claude Desktop, Codex, Projects, Packages.
  - Disabled targets are completely ignored (no watching, no syncing).
  - Setting persists across restarts.

#### FR-15: Bandwidth Control

- **Description**: Throttle sync bandwidth to prevent network saturation.
- **Behavior**:
  - Slider control: 1 MB/s, 5 MB/s, 10 MB/s, 50 MB/s, Unlimited.
  - Implemented via rsync `--bwlimit` flag.
  - Default: Unlimited.

#### FR-16: Notifications

- **Description**: System notifications for important sync events.
- **Events**:
  - Peer connected/disconnected.
  - New packages detected on peer (available for install).
  - Conflict detected requiring attention.
  - Initial sync completed.
  - Sync error requiring user action.
- **Behavior**: Uses UserNotifications framework. Configurable (can be disabled).

---

## 6. Non-Functional Requirements

### Performance

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Sync latency (config files) | < 3 seconds from file save to peer write | Automated timestamp comparison |
| Memory usage (idle) | < 50 MB RSS | Activity Monitor / Instruments |
| Memory usage (active sync) | < 150 MB RSS | Instruments profiling |
| CPU usage (idle) | < 1% | Activity Monitor average over 1 hour |
| CPU usage (active sync) | < 15% | Instruments profiling during bulk sync |
| App launch time | < 1 second to menu bar icon visible | Cold start measurement |
| Bonjour discovery | < 5 seconds to find peer | Network test on standard WiFi |

### Reliability

| Requirement | Description |
|-------------|-------------|
| Zero data loss | No file may be permanently lost. All overwrites produce archived copies. |
| Crash recovery | App automatically restarts via launchd on crash. Sync state is recoverable. |
| Network resilience | Graceful handling of WiFi drops, sleep/wake, network transitions. |
| Idempotent sync | Running sync multiple times produces the same result as running once. |
| Atomic operations | File writes use atomic rename pattern (write to temp, rename to target). |

### Security

| Requirement | Description |
|-------------|-------------|
| Transport encryption | All data transfers over SSH (AES-256-GCM via OpenSSH). |
| Key management | Ed25519 keypair stored in `~/.claudesync/ssh/` with 600 permissions. |
| No cloud exposure | Zero network traffic leaves the local subnet. |
| Pairing verification | Visual 6-digit code confirmation prevents MITM during pairing. |
| No credential storage | No passwords stored. SSH key-based auth only. |

### Compatibility

| Requirement | Description |
|-------------|-------------|
| macOS version | macOS 15.0 (Sequoia) and later |
| Architecture | Universal binary (Apple Silicon + Intel x86_64) |
| Coexistence | Must not interfere with: Time Machine, iCloud Drive, Dropbox, git operations |
| SSH compatibility | Works with default macOS OpenSSH; no custom SSH server required |

### Usability

| Requirement | Description |
|-------------|-------------|
| Zero daily interaction | After pairing, app requires no user input during normal operation. |
| Setup time | Complete pairing in under 2 minutes. |
| Status clarity | Sync state unambiguous at a glance (color-coded icon). |
| Graceful degradation | When peer offline, app remains idle with no errors or popups. |

---

## 7. Technical Architecture Summary

### System Architecture

```
+------------------+          Local Network (WiFi/Ethernet)          +------------------+
|   Machine A      |                                                  |   Machine B      |
|                  |                                                  |                  |
| +-------------+  |     Bonjour (_claudesync._tcp)                   | +-------------+  |
| | ClaudeSync  |--|------ Discovery (NWBrowser/NWListener) ---------|--| ClaudeSync  |  |
| |   App       |  |                                                  | |   App       |  |
| +------+------+  |     Control Channel (NWConnection)               | +------+------+  |
|        |         |------ Heartbeat + Sync Notifications ------------|--|      |         |
|        |         |                                                  |        |         |
| +------+------+  |     Data Channel (rsync over SSH)                | +------+------+  |
| | FileWatcher |  |------ File Transfer (rsync -avz) ---------------|--| FileWatcher |  |
| | (FSEvents)  |  |                                                  | | (FSEvents)  |  |
| +-------------+  |                                                  | +-------------+  |
+------------------+                                                  +------------------+
```

### Component Architecture (Actor Model)

```
@MainActor (UI Layer)
├── MenuBarView (SwiftUI MenuBarExtra)
├── PairingView
├── SettingsView
└── HistoryView

SyncCoordinator (Central orchestrator)
├── Manages sync queue and priorities
├── Handles conflict resolution logic
└── Coordinates between domain actors

Domain Actors (Isolated, concurrent)
├── DiscoveryActor
│   ├── NWBrowser (find peers)
│   └── NWListener (advertise self)
├── ConnectionActor
│   ├── NWConnection (control channel)
│   └── Heartbeat management
├── FileWatcherActor
│   ├── FSEventStream per sync target
│   └── Change event debouncing
├── FileSyncActor
│   ├── rsync process management
│   └── Transfer queue with priorities
└── PackageSyncActor (P1)
    ├── brew list collection
    └── npm list collection
```

### Data Flow

1. **FSEvents** detects file change in watched directory.
2. **FileWatcherActor** applies 2-second per-path quiet-period debounce and emits change event to **SyncCoordinator**.
3. **SyncCoordinator** determines sync tier and priority, checks for conflicts, queues sync operation.
4. **FileSyncActor** executes rsync over SSH to peer machine, registering active PID per destination path.
5. **ConnectionActor** sends sync completion notification over control channel.
6. Peer's **FileWatcherActor** suppresses re-sync for paths being written by active rsync processes (process-lifecycle suppression, released on exit + 1s buffer).

### Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Swift 6 with strict concurrency | Thread safety via actors; eliminates data races |
| FSEvents over polling | Kernel-level efficiency; instant notification; low CPU |
| rsync over SSH | Battle-tested, handles partial transfers, compression, permissions |
| Bonjour/mDNS | Zero-config networking; native macOS support; no server needed |
| NWConnection for control | Modern Network.framework; handles WiFi transitions gracefully |
| Ed25519 keys | Modern, fast, small keys; preferred over RSA |
| No sandbox | Required for SSH, rsync, FSEvents on arbitrary paths, authorized_keys modification |
| Length-prefixed JSON framing | Simple protocol for control messages; easy to debug |

### File System Layout

```
~/.claudesync/
├── config.json          # Pairing metadata, sync targets, settings
├── ssh/
│   ├── id_ed25519      # Private key (mode 600)
│   └── id_ed25519.pub  # Public key
├── ignore              # Custom rsync exclude patterns
├── history.json        # Last 100 sync events
├── conflicts/          # Archived conflict files (30-day retention)
│   └── 2026-05-03/
│       └── .claude/settings.json.machine-b
└── logs/
    └── claudesync.log  # Debug logging (rotated, 10MB max)
```

### Control Channel Protocol

```json
// Heartbeat (every 10 seconds)
{"type": "heartbeat", "timestamp": 1714700000}

// Sync notification
{"type": "sync_complete", "path": "~/.claude/settings.json", "direction": "a_to_b", "size": 2048}

// Conflict notification  
{"type": "conflict", "path": "~/.claude/memory/global.json", "resolution": "newer_wins"}

// Pause/Resume
{"type": "pause_sync"}
{"type": "resume_sync"}
```

---

## 8. Risks & Mitigations

### Technical Risks

| Risk | Severity | Probability | Mitigation |
|------|----------|-------------|------------|
| **Sync loop** — Machine A syncs to B, B's FSEvents fires, B syncs back to A, infinite loop | High | High | Per-file suppression keyed to rsync process lifecycle: track active rsync PIDs per path, suppress FSEvents while rsync writes, release suppression on process exit + 1s buffer. On startup, scan for and remove stale suppression markers from previous crashes. See FR-04 for details. |
| **Large file stalls** — 3GB initial sync of sessions blocks other operations | Medium | High | Priority queue: config files sync first (P0), sessions sync in background (P2). Show progress for initial sync. |
| **SSH connection instability** — WiFi drops mid-transfer | Medium | Medium | rsync `--partial` flag preserves partial transfers. Automatic retry with exponential backoff (1s, 2s, 4s, max 30s). |
| **File permission conflicts** — Different users or permission models | Low | Low | rsync `--no-perms` for cross-user scenarios. Document requirement that both machines use same username. |
| **Clock skew** — Incorrect mtime comparison due to system clock differences | Medium | Low | Use NTP-synced clocks (macOS default). Warn user if clock difference > 5 seconds. |

### Product Risks

| Risk | Severity | Probability | Mitigation |
|------|----------|-------------|------------|
| **Accidental deletion propagation** — User deletes file on A, it propagates to B | High | Medium | Implement "trash before delete" — move deleted files to `~/.claudesync/trash/` on receiving machine before removing. 7-day retention. |
| **Storage bloat** — Conflict archives and trash accumulate | Low | High | Automatic purge: conflicts after 30 days, trash after 7 days. Configurable retention. |
| **Network discovery failure** — Corporate WiFi with client isolation | Medium | Medium | Fallback: manual IP entry in settings. Document network requirements. |
| **User confusion about sync direction** — Unclear which machine is "winning" | Medium | Medium | Clear UI indication of last sync direction per file. Initial sync requires explicit direction confirmation. |

### Security Risks

| Risk | Severity | Probability | Mitigation |
|------|----------|-------------|------------|
| **MITM during pairing** — Attacker intercepts key exchange | High | Low | Visual confirmation code (6 digits) must match on both screens. Keys exchanged only after user confirms match. |
| **Unauthorized access** — Someone with network access tries to pair | Medium | Low | Pairing requires explicit acceptance on both machines. Rate-limit pairing attempts (max 3 per hour). |
| **Key compromise** — SSH private key leaked | High | Very Low | Key stored with 600 permissions. "Re-pair" option regenerates keys. Document secure machine practices. |

---

## 9. Success Metrics

### Primary KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Sync latency** (P95) | < 3 seconds | Automated telemetry: time from FSEvent to rsync completion |
| **Data integrity** | 0 files lost | Checksum verification on synced files; conflict archive completeness |
| **Uptime** | 99.9% (when both machines are on) | App crash count; restart recovery time |
| **Resource efficiency** | <50MB RAM idle, <1% CPU idle | Weekly automated profiling |
| **Pairing success rate** | >95% first attempt | User testing; error log analysis |

### Secondary KPIs

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Daily active sync events** | Fully automated (0 manual interventions) | History log analysis |
| **Conflict rate** | <1% of synced files | Conflict archive count / total sync events |
| **Network recovery time** | <10 seconds after WiFi reconnect | Automated network disruption testing |
| **Initial sync time** (config only) | <30 seconds for ~/.claude/ | Timed measurement on fresh pairing |
| **User satisfaction** | Setup perceived as "easy" | Qualitative testing with target users |

### Quality Gates for Launch

- [ ] Zero data loss across 7 days of continuous operation in dogfood testing
- [ ] Sync latency <3s for 95th percentile across 1000 file changes
- [ ] Successful pairing on 3 different network configurations (home WiFi, office WiFi, Thunderbolt bridge)
- [ ] Clean crash-free operation for 72 hours on both Intel and Apple Silicon
- [ ] Memory usage stable (no leak) over 24-hour run verified by Instruments

---

## 10. Timeline

### Phase 1: Foundation (Weeks 1-3)

| Week | Deliverable |
|------|-------------|
| 1 | Project scaffolding; SwiftUI MenuBarExtra shell; Actor model skeleton; Build system (universal binary) |
| 2 | Bonjour discovery (NWBrowser/NWListener); Control channel (NWConnection with JSON framing); Heartbeat |
| 3 | SSH key generation and exchange; Pairing flow UI; Visual confirmation code; `authorized_keys` installation |

**Milestone**: Two machines can discover each other and pair successfully.

### Phase 2: Core Sync (Weeks 4-6)

| Week | Deliverable |
|------|-------------|
| 4 | FSEvents file watcher with debouncing; Sync loop prevention; rsync process management |
| 5 | Claude Code directory sync (~/.claude/); Smart ignore rules; Bidirectional sync logic |
| 6 | Conflict resolution (newer wins + archive); Claude Desktop and Codex sync targets; Status icon states |

**Milestone**: Full P0 feature set operational. Config changes sync between machines.

### Phase 3: Polish & P1 (Weeks 7-9)

| Week | Deliverable |
|------|-------------|
| 7 | Sync history logging; Environment diff view (UI); Package list collection (brew/npm) |
| 8 | Package diff display and install actions; Project folder sync (opt-in); Bandwidth control |
| 9 | Selective sync toggles; Notifications; Settings persistence; Launch-at-login |

**Milestone**: P1 features complete. App is daily-driver ready.

### Phase 4: Hardening & Release (Weeks 10-12)

| Week | Deliverable |
|------|-------------|
| 10 | Dogfood testing (daily use on real workflows); Bug fixes; Performance profiling |
| 11 | Network edge cases (sleep/wake, WiFi roaming, Thunderbolt); Crash recovery; Memory leak analysis |
| 12 | Code signing and notarization; Distribution packaging (.dmg); Documentation; Release |

**Milestone**: v1.0 release candidate. Signed, notarized, ready for distribution.

### Post-Launch (Weeks 13+)

- User feedback incorporation
- Performance optimization based on real-world usage patterns
- Evaluation of three-machine support for v2.0
- Exploration of selective git-aware sync (respect .gitignore)

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **Bonjour** | Apple's zero-configuration networking protocol (mDNS + DNS-SD) |
| **FSEvents** | macOS kernel subsystem for file system change notifications |
| **rsync** | Unix utility for efficient incremental file transfer |
| **mtime** | File modification timestamp |
| **NWBrowser** | Network.framework class for discovering network services |
| **NWListener** | Network.framework class for advertising network services |
| **NWConnection** | Network.framework class for TCP/UDP connections |
| **Ed25519** | Modern elliptic-curve signature scheme for SSH keys |
| **MCP** | Model Context Protocol — standard for AI tool server communication |
| **Control channel** | Lightweight TCP connection for sync coordination messages |

## Appendix B: Sync Target Summary

| Target | Path | Estimated Size | Priority | Default |
|--------|------|---------------|----------|---------|
| Claude Code | `~/.claude/` | ~3 GB | P0 | Enabled |
| Claude Desktop | `~/Library/Application Support/Claude/` | ~5 MB | P0 | Enabled |
| Codex CLI | `~/.codex/` | ~10 MB | P0 | Enabled |
| Projects | `~/Documents/GitHub/` | ~67 GB (with excludes: ~20 GB) | P1 | Disabled |
| Packages | brew + npm global | N/A (metadata only) | P1 | Disabled |

## Appendix C: Competitive Landscape

| Solution | Limitations vs ClaudeSync |
|----------|--------------------------|
| iCloud Drive | Cannot sync dotfiles; sandboxed; no symlink support; no SSH config sync |
| Dropbox/OneDrive | Cloud-dependent; latency; cannot sync system paths; subscription cost |
| git bare repo (dotfiles) | Manual commits; no session/memory sync; doesn't handle binary files well |
| Syncthing | Requires configuration; no Bonjour; no AI-tool-aware ignore rules; Java dependency |
| Manual rsync scripts | No auto-discovery; no conflict resolution; requires cron/manual triggers |
| Unison | Aging codebase; complex configuration; no macOS-native UI; no menu bar integration |

ClaudeSync differentiates by being purpose-built for AI coding tool synchronization with zero-configuration networking and native macOS integration.
