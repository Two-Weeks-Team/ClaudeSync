# ClaudeSync

> Keep your AI coding environments in perfect sync across Macs

Native macOS menu bar app that auto-discovers your other Mac on the same network and continuously syncs Claude Code, Codex CLI, and project configurations.

![Status](https://img.shields.io/badge/status-in%20development-yellow)

## Key Features

- **Auto-discovery via Bonjour** - Zero-config network discovery of your other Macs
- **Real-time file sync via rsync+SSH** - Efficient, incremental file synchronization
- **Claude Code full sync** - Settings, skills, hooks, memory, and sessions
- **Package sync** - Homebrew formulae, npm global packages, and more
- **One-click pairing** - Simple device pairing with secure authentication
- **Conflict resolution** - Smart handling of simultaneous changes on multiple machines

## Tech Stack

- Swift 6
- SwiftUI
- Network.framework
- macOS 15+

## License

[MIT](LICENSE)
