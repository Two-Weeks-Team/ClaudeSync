# ClaudeSync — Project Instructions

## Project Overview
macOS menu bar tray app for syncing AI coding tool environments (Claude Code, Codex CLI) between two Macs.

## Key Documents
- PRD: `docs/prd/PRD.md`
- Technical Spec: `docs/specs/TECHNICAL_SPEC.md`  
- Tech References: `docs/references/TECH_REFERENCES.md`
- Test Strategy: `docs/specs/TEST_STRATEGY.md`
- Handoff: `HANDOFF.md`

## Tech Stack
- Swift 6.2, SwiftUI MenuBarExtra (.window style)
- Network.framework (Bonjour: NWBrowser/NWListener)
- FSEvents (C API → AsyncStream)
- Foundation.Process (rsync, ssh-keygen)
- macOS 15+ only, No sandbox, No external dependencies

## Architecture
- 3-tier actor model: @MainActor UI → SyncCoordinator → Domain actors
- Bonjour service: `_claudesync._tcp`
- Transport: rsync over SSH with dedicated Ed25519 keypair
- 3-Tier sync: Real-time (<3s) / Batched (5min) / On-demand

## Critical Constraints
- macOS Sequoia uses openrsync (not GNU rsync). Safe flags only: `--archive --compress --delete --update --itemize-changes`
- No sandbox: needs rsync, ssh-keygen, Full Disk Access
- Sync loop prevention: PID-based per-file suppression (not timer-based)
- Remote Login (sshd) must be enabled on both Macs
- Pairing code = SHA-256(pubkey_A || pubkey_B) truncated to 6 digits

## Build & Run
```bash
# Open in Xcode
open ClaudeSync.xcodeproj

# Or build from CLI
xcodebuild -scheme ClaudeSync -configuration Debug build
```

## Git Workflow
- Branch from `main` for features
- PR-based merges (no squash)
- Commit messages: `feat:`, `fix:`, `docs:`, `test:`, `chore:`
