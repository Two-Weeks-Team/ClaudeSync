# ClaudeSync Technical References

> **Generated**: 2026-05-03  
> **Target Platform**: macOS 15+ (Sequoia)  
> **Language**: Swift 6 / Swift 6.2  
> **Architecture**: Menu bar utility with peer-to-peer file sync

---

## Table of Contents

1. [SwiftUI MenuBarExtra](#1-swiftui-menubarextra)
2. [Network.framework Bonjour](#2-networkframework-bonjour)
3. [FSEvents API](#3-fsevents-api)
4. [rsync on macOS](#4-rsync-on-macos)
5. [SSH Key Management](#5-ssh-key-management)
6. [Swift 6 Strict Concurrency](#6-swift-6-strict-concurrency)
7. [macOS App Distribution](#7-macos-app-distribution)
8. [Xcode Project Setup](#8-xcode-project-setup)

---

## 1. SwiftUI MenuBarExtra

### Version / API Level

- **Available since**: macOS 13 (Ventura), refined through macOS 14-15
- **Current stable**: macOS 15.x Sequoia
- **Styles**: `.menu` (default) and `.window`

### Official Documentation

- [MenuBarExtra | Apple Developer Documentation](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Build a macOS menu bar utility in SwiftUI](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/)

### Key Code Patterns

```swift
import SwiftUI

@main
struct ClaudeSyncApp: App {
    var body: some Scene {
        // Window style: allows custom SwiftUI views (sliders, toggles, etc.)
        MenuBarExtra("ClaudeSync", systemImage: "arrow.triangle.2.circlepath") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
        
        // Alternative: Menu style (standard NSMenu-like items)
        // MenuBarExtra("ClaudeSync", systemImage: "arrow.triangle.2.circlepath") {
        //     Button("Sync Now") { /* ... */ }
        //     Divider()
        //     Button("Quit") { NSApplication.shared.terminate(nil) }
        // }
        // .menuBarExtraStyle(.menu)
    }
}
```

#### Using `isInserted` Binding for Programmatic Control

```swift
@main
struct ClaudeSyncApp: App {
    @State private var isMenuPresented = true
    
    var body: some Scene {
        MenuBarExtra("ClaudeSync", systemImage: "arrow.triangle.2.circlepath",
                     isInserted: $isMenuPresented) {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
```

### Known Gotchas and Limitations

| Issue | Description | Workaround |
|-------|-------------|------------|
| **No programmatic dismiss** | `.window` style cannot be dismissed from within the view | Use [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) library or track FB11984872 |
| **No `.onAppear` in menu style** | Views inside `.menu` style never fire `.onAppear` | Use `.window` style or manage state externally |
| **Settings window issues (15.5+)** | `SettingsLink` fails silently in MenuBarExtra on macOS 15.5 | Declare a hidden `WindowGroup` *before* the `Settings` scene |
| **No fade animation** | Window style popup doesn't fade on dismiss like native menus | Accept or use AppKit overlay |
| **Menu not refreshing** | `.menu` style body not re-evaluated on open | Use ObservableObject with manual trigger |
| **Scene ordering matters** | Scene declaration order affects `openSettings()` behavior | Place utility scenes before Settings |

### Recommended Approach for ClaudeSync

- Use `.window` style for the main popover (need custom UI with sync status, peer list, progress indicators)
- Consider [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) for programmatic show/hide control
- For settings: use a separate `Window` scene opened via `openWindow` environment action
- Set `LSUIElement = YES` to hide from Dock (see Section 8)

---

## 2. Network.framework Bonjour

### Version / API Level

- **Framework**: Network.framework (available since macOS 10.14)
- **Key classes**: `NWBrowser`, `NWListener`, `NWConnection`
- **Protocol**: mDNS/DNS-SD (Bonjour) over `_tcp` or `_udp`

### Official Documentation

- [NWListener | Apple Developer Documentation](https://developer.apple.com/documentation/network/nwlistener)
- [NWBrowser | Apple Developer Documentation](https://developer.apple.com/documentation/network/nwbrowser)
- [Advances in Networking, Part 2 - WWDC19](https://developer.apple.com/videos/play/wwdc2019/713/)
- [NSBonjourServices | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices)

### Key Code Patterns

#### Service Advertising (NWListener)

```swift
import Network

actor PeerAdvertiser {
    private var listener: NWListener?
    private let serviceName: String
    private let serviceType = "_claudesync._tcp"
    
    init(serviceName: String) {
        self.serviceName = serviceName
    }
    
    func startAdvertising() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        listener = try NWListener(using: parameters)
        listener?.service = NWListener.Service(
            name: serviceName,
            type: serviceType
        )
        
        // Set TXT record metadata
        let txtRecord = NWTXTRecord()
        txtRecord[key: "hostname"] = Host.current().localizedName ?? "Unknown"
        txtRecord[key: "version"] = "1.0"
        listener?.service?.txtRecord = txtRecord.data
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateUpdate(state) }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }
        
        listener?.start(queue: .global())
    }
    
    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("Listener ready on port: \(listener?.port?.rawValue ?? 0)")
        case .failed(let error):
            print("Listener failed: \(error)")
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        // Handle incoming peer connection
        connection.start(queue: .global())
    }
    
    func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }
}
```

#### Service Discovery (NWBrowser)

```swift
import Network

actor PeerBrowser {
    private var browser: NWBrowser?
    private let serviceType = "_claudesync._tcp"
    
    struct DiscoveredPeer: Sendable {
        let name: String
        let endpoint: NWEndpoint
        let metadata: [String: String]
    }
    
    func startBrowsing() -> AsyncStream<[DiscoveredPeer]> {
        AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            
            browser = NWBrowser(
                for: .bonjour(type: serviceType, domain: nil),
                using: parameters
            )
            
            browser?.browseResultsChangedHandler = { results, changes in
                let peers = results.compactMap { result -> DiscoveredPeer? in
                    guard case .service(let name, _, _, _) = result.endpoint else {
                        return nil
                    }
                    var metadata: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata {
                        // Extract TXT record entries
                        metadata["hostname"] = record[key: "hostname"]
                        metadata["version"] = record[key: "version"]
                    }
                    return DiscoveredPeer(
                        name: name,
                        endpoint: result.endpoint,
                        metadata: metadata
                    )
                }
                continuation.yield(peers)
            }
            
            browser?.stateUpdateHandler = { state in
                if case .failed(_) = state {
                    continuation.finish()
                }
            }
            
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stopBrowsing() }
            }
            
            browser?.start(queue: .global())
        }
    }
    
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }
}
```

#### Establishing a Connection

```swift
func connect(to endpoint: NWEndpoint) async throws -> NWConnection {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    
    let connection = NWConnection(to: endpoint, using: parameters)
    
    return try await withCheckedThrowingContinuation { continuation in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                continuation.resume(returning: connection)
            case .failed(let error):
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}
```

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Local Network permission** | macOS prompts user for local network access | Add `NSLocalNetworkUsageDescription` to Info.plist |
| **Service type must match** | NWBrowser type must match NWListener service type exactly | Use a shared constant |
| **Peer-to-peer not default** | Must explicitly set `includePeerToPeer = true` | Always set on parameters |
| **TXT record size limit** | DNS-SD TXT records limited to ~8KB total | Keep metadata minimal |
| **mDNS on VPN** | Bonjour may not work across VPN segments | Document LAN-only limitation |
| **Firewall blocking** | macOS firewall can block listener | App must be signed or user must allow |

### Recommended Approach for ClaudeSync

- Use `_claudesync._tcp` as the Bonjour service type
- Advertise with `NWListener`; include machine name and sync folder path in TXT record
- Discover peers with `NWBrowser`; expose discovered peers as `AsyncStream`
- Use `NWConnection` for the control channel (handshake, negotiation)
- Actual file transfer via rsync over SSH (not over NWConnection)
- Wrap in actors for thread safety under Swift 6

---

## 3. FSEvents API

### Version / API Level

- **Framework**: CoreServices (FSEvents C API)
- **Available since**: macOS 10.5
- **Flags of interest**: `kFSEventStreamCreateFlagFileEvents` (per-file events, macOS 10.7+), `kFSEventStreamCreateFlagUseCFTypes`
- **Swift wrappers**: [FSEventsWrapper](https://github.com/Frizlab/FSEventsWrapper) (supports AsyncStream)

### Official Documentation

- [File System Events Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [FSEventStreamCreate | Apple Developer Documentation](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate)

### Key Code Patterns

#### Direct FSEvents C API Usage (Swift 6 Compatible)

```swift
import CoreServices

actor FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    
    init(paths: [String], latency: CFTimeInterval = 1.0) {
        self.paths = paths
        self.latency = latency
    }
    
    func startWatching() -> AsyncStream<[FileChangeEvent]> {
        AsyncStream { continuation in
            let context = Unmanaged.passRetained(
                FileWatcherContext(continuation: continuation)
            )
            
            var fsContext = FSEventStreamContext(
                version: 0,
                info: context.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            
            let flags: FSEventStreamCreateFlags =
                UInt32(kFSEventStreamCreateFlagFileEvents) |
                UInt32(kFSEventStreamCreateFlagUseCFTypes) |
                UInt32(kFSEventStreamCreateFlagNoDefer)
            
            guard let eventStream = FSEventStreamCreate(
                nil,
                fsEventsCallback,
                &fsContext,
                paths as CFArray,
                FSEventsGetCurrentEventId(),
                latency,
                flags
            ) else {
                continuation.finish()
                return
            }
            
            self.stream = eventStream
            FSEventStreamSetDispatchQueue(eventStream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(eventStream)
            
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stopWatching() }
                context.release()
            }
        }
    }
    
    func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

// Sendable context for the callback
final class FileWatcherContext: @unchecked Sendable {
    let continuation: AsyncStream<[FileChangeEvent]>.Continuation
    init(continuation: AsyncStream<[FileChangeEvent]>.Continuation) {
        self.continuation = continuation
    }
}

struct FileChangeEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventId: FSEventStreamEventId
    
    var isModified: Bool { flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 }
    var isCreated: Bool { flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 }
    var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
    var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
}

// C callback function (must be a free function, not a closure)
private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let context = Unmanaged<FileWatcherContext>.fromOpaque(info).takeUnretainedValue()
    
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
    
    var events: [FileChangeEvent] = []
    for i in 0..<numEvents {
        events.append(FileChangeEvent(
            path: paths[i],
            flags: eventFlags[i],
            eventId: eventIds[i]
        ))
    }
    
    context.continuation.yield(events)
}
```

#### Alternative: DispatchSource for Single File/Directory

```swift
// For monitoring a single directory (simpler but less scalable)
func monitorDirectory(at url: URL) -> AsyncStream<Void> {
    AsyncStream { continuation in
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            continuation.finish()
            return
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility)
        )
        
        source.setEventHandler {
            continuation.yield(())
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        continuation.onTermination = { _ in
            source.cancel()
        }
        
        source.resume()
    }
}
```

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Coalesced events** | FSEvents coalesces events within the latency window | Use short latency (0.5-1s) and reconcile with filesystem state |
| **Always recursive** | FSEvents monitors entire directory tree; no non-recursive option | Filter events by depth if needed |
| **Historical events** | Using `kFSEventStreamEventIdSinceNow` skips startup scan | Store last event ID for resumption |
| **Renamed items** | Renames produce two events (old path removed, new path created) | Correlate by event ID proximity |
| **Symbolic links** | FSEvents follows symlinks by default | Be aware of infinite loops |
| **C API in Swift** | Callback must be a C function, not a closure | Use context pointer pattern |
| **Sendable concerns** | Context passed to C callback must be carefully managed | Use `@unchecked Sendable` wrapper |

### Recommended Approach for ClaudeSync

- Use FSEvents (not DispatchSource) for monitoring sync directories -- it handles recursive trees natively
- Set `kFSEventStreamCreateFlagFileEvents` for per-file granularity
- Wrap in an actor with AsyncStream output
- Debounce events (1-2 seconds) before triggering sync to avoid rapid fire
- Store `FSEventsGetCurrentEventId()` to resume monitoring across app restarts
- Consider [FSEventsWrapper](https://github.com/Frizlab/FSEventsWrapper) if you want a maintained Swift package

---

## 4. rsync on macOS

### Version / API Level

- **macOS Sonoma (14)**: rsync 2.6.9 (2006 vintage, GPLv2)
- **macOS Sequoia (15)**: **openrsync** (OpenBSD reimplementation, ISC license)
- **Homebrew rsync**: 3.4.1+ (GPLv3, full feature set)

### Critical Change: openrsync on Sequoia

Apple replaced the ancient rsync 2.6.9 with **openrsync** starting in macOS 15 Sequoia. openrsync is a clean-room reimplementation that supports only a subset of rsync flags.

### Official Documentation

- [openrsync man page (macOS)](https://ss64.com/mac/rsync.html)
- [rsync options reference](https://ss64.com/mac/rsync_options.html)
- [rsync replaced with openrsync - Der Flounder](https://derflounder.wordpress.com/2025/04/06/rsync-replaced-with-openrsync-on-macos-sequoia/)

### Key Flags (Compatible with openrsync)

| Flag | Purpose | Notes |
|------|---------|-------|
| `-a` / `--archive` | Recursive + preserve permissions, times, group, owner, symlinks | Equivalent to `-rlptgoD` |
| `-z` / `--compress` | Compress during transfer | Useful over slow networks |
| `--delete` | Remove destination files not in source | Creates true mirror |
| `--update` / `-u` | Skip files newer on destination | Prevents overwriting newer edits |
| `-e ssh` | Use SSH as transport | Default in most setups |
| `--itemize-changes` / `-i` | Output per-file change summary | Good for logging/progress |
| `-v` / `--verbose` | Increase verbosity | For debugging |
| `--exclude` | Exclude pattern from sync | For .git, .DS_Store, etc. |
| `-n` / `--dry-run` | Show what would transfer without doing it | Preview mode |

### Flags NOT Supported by openrsync (Sequoia)

| Flag | Status |
|------|--------|
| `--log-file` | Not available |
| `-E` (extended attrs) | Can cause crashes |
| `--backup-dir` | Broken |
| `--progress` | Limited support |
| `--partial` | May not work |

### Key Code Patterns (Swift Subprocess)

```swift
import Foundation
// Swift 6.2+: import Subprocess (when available)
// For now, use Foundation.Process

actor RsyncManager {
    struct SyncResult: Sendable {
        let exitCode: Int32
        let output: String
        let itemizedChanges: [String]
    }
    
    func sync(
        source: String,
        destination: String, // user@host:/path
        sshKeyPath: String,
        excludes: [String] = [".git", ".DS_Store", "*.swp"]
    ) async throws -> SyncResult {
        var arguments = [
            "--archive",
            "--compress",
            "--delete",
            "--update",
            "--itemize-changes",
            "-e", "ssh -i \(sshKeyPath) -o StrictHostKeyChecking=accept-new",
        ]
        
        for exclude in excludes {
            arguments.append(contentsOf: ["--exclude", exclude])
        }
        
        // Ensure source path ends with / for content-only sync
        let normalizedSource = source.hasSuffix("/") ? source : source + "/"
        arguments.append(normalizedSource)
        arguments.append(destination)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = arguments
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        
        let changes = output
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        
        return SyncResult(
            exitCode: process.terminationStatus,
            output: output,
            itemizedChanges: changes
        )
    }
    
    /// Dry run to preview changes
    func preview(
        source: String,
        destination: String,
        sshKeyPath: String
    ) async throws -> [String] {
        // Same as sync but with --dry-run flag prepended
        // Returns list of files that would change
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "--archive", "--compress", "--delete",
            "--update", "--itemize-changes", "--dry-run",
            "-e", "ssh -i \(sshKeyPath)",
            source.hasSuffix("/") ? source : source + "/",
            destination
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}
```

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **openrsync limited flags** | Sequoia's rsync lacks many flags | Use only the common subset or bundle Homebrew rsync |
| **Stalling on large transfers** | openrsync reported to stall after 800-1300 files | Implement timeout + retry logic |
| **No `--progress` details** | Limited progress reporting in openrsync | Parse `--itemize-changes` for status |
| **Trailing slash semantics** | `source/` syncs contents; `source` syncs the directory itself | Always normalize paths |
| **SSH key passphrase** | rsync cannot handle interactive passphrase prompts | Use keys without passphrase or ssh-agent |

### Recommended Approach for ClaudeSync

- **Target the openrsync-compatible flag subset** for zero-dependency operation
- Core flags: `--archive --compress --delete --update --itemize-changes -e ssh`
- Bundle or recommend Homebrew rsync 3.x as optional enhancement for power users
- Parse `--itemize-changes` output for UI progress display
- Always use `--dry-run` first for preview/conflict detection
- Use Swift 6.2's Subprocess package when it stabilizes (currently use `Foundation.Process`)
- Implement timeout handling to work around openrsync stalling issues

---

## 5. SSH Key Management

### Version / API Level

- **Algorithm**: Ed25519 (current standard, ~10 years of production use)
- **Key size**: 256-bit (fixed, always 256 bits)
- **Tool**: `ssh-keygen` (ships with macOS)
- **Config**: `~/.ssh/config`, `~/.ssh/authorized_keys`

### Official Documentation

- [SSH Key Best Practices for 2025](https://www.brandonchecketts.com/archives/ssh-ed25519-key-best-practices-for-2025)
- [How to Configure SSH Key Authentication](https://oneuptime.com/blog/post/2026-01-24-configure-ssh-key-authentication/view)

### Key Code Patterns

#### Programmatic Key Generation

```swift
import Foundation

actor SSHKeyManager {
    private let sshDirectory: URL
    private let keyName: String
    
    init(keyName: String = "claudesync_ed25519") {
        self.sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        self.keyName = keyName
    }
    
    var privateKeyPath: String {
        sshDirectory.appendingPathComponent(keyName).path
    }
    
    var publicKeyPath: String {
        sshDirectory.appendingPathComponent("\(keyName).pub").path
    }
    
    /// Generate a new Ed25519 key pair for ClaudeSync
    func generateKeyPair(comment: String = "ClaudeSync") async throws {
        // Ensure .ssh directory exists with correct permissions
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDirectory.path) {
            try fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        }
        // Set directory permissions to 700
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDirectory.path)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-t", "ed25519",
            "-f", privateKeyPath,
            "-N", "",              // Empty passphrase for automated use
            "-C", comment
        ]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SSHKeyError.generationFailed
        }
        
        // Set correct permissions
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyPath)
    }
    
    /// Read the public key for sharing with peers
    func readPublicKey() throws -> String {
        try String(contentsOfFile: publicKeyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Add a peer's public key to authorized_keys
    func authorizeKey(_ publicKey: String) throws {
        let authorizedKeysPath = sshDirectory.appendingPathComponent("authorized_keys").path
        let fm = FileManager.default
        
        if fm.fileExists(atPath: authorizedKeysPath) {
            // Check if key already exists
            let existing = try String(contentsOfFile: authorizedKeysPath, encoding: .utf8)
            if existing.contains(publicKey) { return }
            
            // Append key
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: authorizedKeysPath))
            handle.seekToEndOfFile()
            handle.write("\n\(publicKey)\n".data(using: .utf8)!)
            handle.closeFile()
        } else {
            try publicKey.write(toFile: authorizedKeysPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeysPath)
        }
    }
    
    /// Add or update SSH config entry for a ClaudeSync peer
    func configureHost(
        name: String,
        hostname: String,
        user: String,
        port: Int = 22
    ) throws {
        let configPath = sshDirectory.appendingPathComponent("config").path
        let fm = FileManager.default
        
        let entry = """
        
        # ClaudeSync peer: \(name)
        Host claudesync-\(name)
            HostName \(hostname)
            User \(user)
            Port \(port)
            IdentityFile \(privateKeyPath)
            StrictHostKeyChecking accept-new
            IdentitiesOnly yes
        
        """
        
        if fm.fileExists(atPath: configPath) {
            var config = try String(contentsOfFile: configPath, encoding: .utf8)
            // Remove existing entry for this peer if present
            let pattern = "# ClaudeSync peer: \(name)\nHost claudesync-\(name)[\\s\\S]*?(?=\\n# |\\nHost |\\z)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                config = regex.stringByReplacingMatches(
                    in: config,
                    range: NSRange(config.startIndex..., in: config),
                    withTemplate: ""
                )
            }
            config += entry
            try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        } else {
            try entry.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }
    
    /// Remove a peer's authorized key
    func deauthorizeKey(comment: String) throws {
        let authorizedKeysPath = sshDirectory.appendingPathComponent("authorized_keys").path
        var content = try String(contentsOfFile: authorizedKeysPath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.contains(comment) && !$0.isEmpty }
        content = lines.joined(separator: "\n") + "\n"
        try content.write(toFile: authorizedKeysPath, atomically: true, encoding: .utf8)
    }
    
    enum SSHKeyError: Error {
        case generationFailed
        case keyNotFound
        case permissionDenied
    }
}
```

### Required File Permissions

| File | Permission | Octal |
|------|-----------|-------|
| `~/.ssh/` | `drwx------` | 700 |
| `~/.ssh/id_ed25519` | `-rw-------` | 600 |
| `~/.ssh/id_ed25519.pub` | `-rw-r--r--` | 644 |
| `~/.ssh/authorized_keys` | `-rw-------` | 600 |
| `~/.ssh/config` | `-rw-------` | 600 |

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Passphrase handling** | Cannot automate passphrase-protected keys easily | Generate without passphrase for ClaudeSync keys |
| **Permission strictness** | SSH refuses to use keys with wrong permissions | Always set permissions programmatically |
| **ssh-agent** | Agent not guaranteed to be running | Don't rely on agent; use IdentityFile directly |
| **Multiple keys** | SSH may try wrong key first | Use `IdentitiesOnly yes` in config |
| **known_hosts** | First connection prompts for host verification | Use `StrictHostKeyChecking accept-new` |
| **Key rotation** | No built-in rotation mechanism | Implement in-app key rotation with re-pairing |

### Recommended Approach for ClaudeSync

- Generate a dedicated Ed25519 key pair per ClaudeSync installation (`~/.ssh/claudesync_ed25519`)
- Exchange public keys during Bonjour-based pairing handshake
- Add peer public keys to `~/.ssh/authorized_keys` with a ClaudeSync comment tag
- Manage `~/.ssh/config` entries with `claudesync-{peerName}` host aliases
- Use `IdentitiesOnly yes` to prevent SSH from trying other keys
- Implement key cleanup on unpair/remove peer

---

## 6. Swift 6 Strict Concurrency

### Version / API Level

- **Swift 6.0**: Strict concurrency checking enabled by default (complete data race safety)
- **Swift 6.2** (WWDC 2025): "Approachable Concurrency" -- `@concurrent`, `nonisolated(nonsending)`, default MainActor isolation
- **Xcode 16+**: Ships with Swift 6.x toolchain

### Official Documentation

- [Swift 6 Concurrency | Hacking with Swift](https://www.hackingwithswift.com/swift/6.0/concurrency)
- [Approachable Concurrency in Swift 6.2 | SwiftLee](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
- [@concurrent explained | SwiftLee](https://www.avanderlee.com/concurrency/concurrent-explained-with-code-examples/)
- [Swift 6.2 Concurrency Changes | Donny Wals](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)

### Key Concepts

#### Swift 6.2 Default Behavior Changes

| Feature | Swift 6.0 | Swift 6.2 |
|---------|-----------|-----------|
| `nonisolated async` function | Ran on global executor (background) | Runs on caller's actor by default |
| Default isolation | None | `@MainActor` (with `DefaultIsolation` setting) |
| Background work | Implicit | Requires explicit `@concurrent` |
| Non-sending behavior | N/A | `nonisolated(nonsending)` keyword |

### Key Code Patterns

#### Actor for Shared Mutable State

```swift
/// Manages sync state across the application
actor SyncStateManager {
    private var activeSyncs: [String: SyncStatus] = [:]
    private var peerConnections: [String: PeerConnection] = [:]
    
    enum SyncStatus: Sendable {
        case idle
        case syncing(progress: Double)
        case completed(Date)
        case failed(String)
    }
    
    func updateStatus(for peer: String, status: SyncStatus) {
        activeSyncs[peer] = status
    }
    
    func getStatus(for peer: String) -> SyncStatus {
        activeSyncs[peer] ?? .idle
    }
    
    func allStatuses() -> [String: SyncStatus] {
        activeSyncs
    }
}
```

#### @MainActor for UI State

```swift
import SwiftUI

@MainActor
@Observable
final class SyncViewModel {
    var peers: [PeerInfo] = []
    var syncStatus: SyncStatus = .idle
    var lastSyncTime: Date?
    var errorMessage: String?
    
    private let stateManager: SyncStateManager
    private let peerBrowser: PeerBrowser
    
    init(stateManager: SyncStateManager, peerBrowser: PeerBrowser) {
        self.stateManager = stateManager
        self.peerBrowser = peerBrowser
    }
    
    func startMonitoring() {
        Task {
            // This runs on MainActor (Swift 6.2 default)
            for await discoveredPeers in await peerBrowser.startBrowsing() {
                self.peers = discoveredPeers.map { PeerInfo(from: $0) }
            }
        }
    }
    
    func triggerSync(for peer: PeerInfo) {
        Task {
            syncStatus = .syncing
            do {
                // Call into actor -- automatically suspends and switches context
                let result = try await performSync(peer: peer)
                syncStatus = .completed
                lastSyncTime = Date()
            } catch {
                syncStatus = .error
                errorMessage = error.localizedDescription
            }
        }
    }
    
    /// Explicitly runs off the main actor
    @concurrent
    private func performSync(peer: PeerInfo) async throws -> SyncResult {
        // Heavy work runs on cooperative thread pool
        let rsync = RsyncManager()
        return try await rsync.sync(
            source: peer.syncPath,
            destination: peer.remoteDestination,
            sshKeyPath: peer.sshKeyPath
        )
    }
}
```

#### AsyncStream for Cross-Actor Communication

```swift
/// Bridge between FSEvents actor and UI layer
actor FileChangeCoordinator {
    private let fileWatcher: FileWatcher
    private let syncDebounceInterval: Duration = .seconds(2)
    
    init(watchPaths: [String]) {
        self.fileWatcher = FileWatcher(paths: watchPaths)
    }
    
    /// Debounced stream of sync-triggering events
    func debouncedChanges() -> AsyncStream<[FileChangeEvent]> {
        AsyncStream { continuation in
            Task {
                var pendingEvents: [FileChangeEvent] = []
                var debounceTask: Task<Void, Never>?
                
                for await events in await fileWatcher.startWatching() {
                    pendingEvents.append(contentsOf: events)
                    
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: syncDebounceInterval)
                        guard !Task.isCancelled else { return }
                        continuation.yield(pendingEvents)
                        pendingEvents = []
                    }
                }
                
                continuation.finish()
            }
        }
    }
}
```

#### Sendable Types

```swift
/// All types crossing actor boundaries must be Sendable
struct PeerInfo: Sendable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let syncPath: String
    let remoteDestination: String
    let sshKeyPath: String
    let lastSeen: Date
}

struct SyncResult: Sendable {
    let exitCode: Int32
    let filesChanged: Int
    let bytesTransferred: Int64
    let duration: Duration
    let itemizedChanges: [String]
}

/// For non-Sendable types that must cross boundaries
/// Use @unchecked Sendable with careful manual audit
final class NWConnectionWrapper: @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    
    init(_ connection: NWConnection) {
        self.connection = connection
    }
}
```

#### Feature Flag for Swift 6.2

```swift
// In Package.swift or build settings:
// -enable-upcoming-feature DefaultIsolation=MainActor
// -enable-upcoming-feature NonIsolatedNonSendingByDefault

// With these flags, all types default to @MainActor isolation
// Use @concurrent for explicitly background work
```

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **NWConnection not Sendable** | Network.framework types predate strict concurrency | Wrap in `@unchecked Sendable` with manual audit |
| **C callbacks** | FSEvents callbacks can't capture actor-isolated state | Use Unmanaged pointer + continuation pattern |
| **Process class** | Foundation.Process not fully Sendable | Wrap in actor or use swift-subprocess |
| **nonisolated(nonsending) in 6.2** | Async functions now inherit caller isolation | Add `@concurrent` for intentional background work |
| **Global variables** | Must be `let`, `actor`-isolated, or `nonisolated(unsafe)` | Prefer actor-scoped state |
| **Callback-based APIs** | Many Apple frameworks still use callbacks | Convert to AsyncStream/withCheckedContinuation |

### Recommended Approach for ClaudeSync

- Enable Swift 6 strict concurrency mode from the start
- Use actors for all shared mutable state (SyncState, PeerList, FileWatcher)
- Use `@MainActor` + `@Observable` for all UI-facing view models
- Use `@concurrent` (Swift 6.2) for explicitly background-threaded work (rsync, file hashing)
- Bridge callback APIs (FSEvents, Network.framework) to `AsyncStream`
- Make all data transfer types `Sendable` structs
- Consider enabling `DefaultIsolation=MainActor` for Swift 6.2 to reduce boilerplate

---

## 7. macOS App Distribution

### Version / API Level

- **Tool**: `xcrun notarytool` (replaced `altool` in Xcode 14+)
- **Requirement**: Hardened Runtime (mandatory for notarization)
- **Certificate**: "Developer ID Application" (for apps outside Mac App Store)
- **Supported formats**: `.app` (in `.zip` or `.dmg`)

### Official Documentation

- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

### Complete Distribution Workflow

```bash
#!/bin/bash
# ClaudeSync distribution script

APP_NAME="ClaudeSync"
BUNDLE_ID="com.yourteam.claudesync"
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
KEYCHAIN_PROFILE="claudesync-notary"

# 1. Build the release archive
xcodebuild archive \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "build/$APP_NAME.xcarchive"

# 2. Export the .app from the archive
xcodebuild -exportArchive \
    -archivePath "build/$APP_NAME.xcarchive" \
    -exportPath "build/export" \
    -exportOptionsPlist ExportOptions.plist

# 3. Sign with Hardened Runtime + entitlements
codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "ClaudeSync.entitlements" \
    "build/export/$APP_NAME.app"

# 4. Verify signature
codesign --verify --deep --strict "build/export/$APP_NAME.app"
spctl --assess --type execute "build/export/$APP_NAME.app"

# 5. Create DMG for distribution
hdiutil create -volname "$APP_NAME" \
    -srcfolder "build/export/$APP_NAME.app" \
    -ov -format UDZO \
    "build/$APP_NAME.dmg"

# 6. Sign the DMG
codesign --sign "$SIGNING_IDENTITY" "build/$APP_NAME.dmg"

# 7. Submit for notarization
xcrun notarytool submit "build/$APP_NAME.dmg" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# 8. Staple the notarization ticket
xcrun stapler staple "build/$APP_NAME.dmg"

# 9. Verify stapling
xcrun stapler validate "build/$APP_NAME.dmg"
```

### One-Time Credential Setup

```bash
# Store notarization credentials in keychain
xcrun notarytool store-credentials "claudesync-notary" \
    --apple-id "your@email.com" \
    --team-id "YOURTEAMID" \
    --password "app-specific-password-from-apple-id"
```

### Entitlements File for ClaudeSync

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Hardened Runtime (required for notarization) -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
    
    <!-- Network access for Bonjour and SSH -->
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    
    <!-- File access for sync directories -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    
    <!-- Allow spawning subprocesses (rsync, ssh-keygen) -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    
    <!-- Disable library validation for subprocess compatibility -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Non-sandboxed + notarized** | Requires Hardened Runtime but NOT App Sandbox | Set `com.apple.security.app-sandbox` to `false` |
| **Subprocess execution** | Hardened Runtime restricts spawning processes | May need `com.apple.security.cs.disable-library-validation` |
| **Notarization service delays** | Apple service can be slow (minutes to hours) | Use `--wait` flag; implement retry in CI |
| **Service outages** | Notarization service has had reported outages in 2026 | Build in fallback/retry logic for CI |
| **Deep signing** | Frameworks and helpers must all be signed | Use `--deep` flag or sign individually |
| **Gatekeeper quarantine** | Users may still see "unidentified developer" if download method adds quarantine | Staple the notarization ticket |

### Recommended Approach for ClaudeSync

- **Non-sandboxed**: ClaudeSync needs filesystem access and subprocess execution (rsync, ssh-keygen)
- **Hardened Runtime**: Required for notarization; use entitlements for needed capabilities
- **Developer ID Application**: Sign with this certificate type for direct distribution
- **DMG distribution**: Package as DMG with drag-to-Applications design
- **Automate in CI**: Script the build, sign, notarize, staple pipeline
- **Consider Sparkle**: Add [Sparkle](https://sparkle-project.org/) framework for auto-updates

---

## 8. Xcode Project Setup

### Version / API Level

- **Xcode**: 16.x+ (ships with Swift 6.x, macOS 15 SDK)
- **Deployment target**: macOS 15.0 (Sequoia)
- **App lifecycle**: SwiftUI App protocol with MenuBarExtra

### Official Documentation

- [LSUIElement | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [NSBonjourServices | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices)
- [NSLocalNetworkUsageDescription | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)

### Info.plist Configuration

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Menu bar only: hide from Dock and Cmd+Tab -->
    <key>LSUIElement</key>
    <true/>
    
    <!-- Bonjour service types this app browses/advertises -->
    <key>NSBonjourServices</key>
    <array>
        <string>_claudesync._tcp</string>
    </array>
    
    <!-- Local network usage description (shown in permission prompt) -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>ClaudeSync uses the local network to discover other ClaudeSync instances on your network for file synchronization.</string>
    
    <!-- Application category -->
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    
    <!-- Minimum system version -->
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    
    <!-- Bundle identifiers -->
    <key>CFBundleIdentifier</key>
    <string>com.yourteam.claudesync</string>
    <key>CFBundleName</key>
    <string>ClaudeSync</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeSync</string>
    
    <!-- Login item support -->
    <key>SMPrivilegedExecutables</key>
    <dict/>
</dict>
</plist>
```

### Project Structure

```
ClaudeSync/
├── ClaudeSync.xcodeproj/
├── ClaudeSync/
│   ├── ClaudeSyncApp.swift          # @main App with MenuBarExtra
│   ├── Info.plist
│   ├── ClaudeSync.entitlements
│   ├── Assets.xcassets/
│   │   └── AppIcon.appiconset/
│   ├── Views/
│   │   ├── MenuBarView.swift        # Main popover content
│   │   ├── PeerListView.swift       # Discovered peers
│   │   ├── SyncStatusView.swift     # Current sync progress
│   │   └── SettingsView.swift       # Configuration
│   ├── ViewModels/
│   │   ├── SyncViewModel.swift      # @MainActor @Observable
│   │   └── SettingsViewModel.swift
│   ├── Services/
│   │   ├── PeerAdvertiser.swift     # NWListener actor
│   │   ├── PeerBrowser.swift        # NWBrowser actor
│   │   ├── FileWatcher.swift        # FSEvents actor
│   │   ├── RsyncManager.swift       # Process management actor
│   │   ├── SSHKeyManager.swift      # Key generation/management actor
│   │   └── SyncCoordinator.swift    # Orchestrates sync workflow
│   └── Models/
│       ├── PeerInfo.swift           # Sendable peer data
│       ├── SyncConfiguration.swift  # User settings
│       └── FileChangeEvent.swift    # FSEvents event model
├── ClaudeSyncTests/
└── README.md
```

### App Entry Point

```swift
import SwiftUI

@main
struct ClaudeSyncApp: App {
    @State private var viewModel = SyncViewModel(
        stateManager: SyncStateManager(),
        peerBrowser: PeerBrowser()
    )
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Label("ClaudeSync", systemImage: statusIcon)
        }
        .menuBarExtraStyle(.window)
        
        // Settings window (opened via openWindow)
        Window("ClaudeSync Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 400)
    }
    
    private var statusIcon: String {
        switch viewModel.syncStatus {
        case .idle: return "arrow.triangle.2.circlepath"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "exclamationmark.triangle"
        case .completed: return "checkmark.circle"
        }
    }
}
```

### Build Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `SWIFT_VERSION` | 6.0 | Enable strict concurrency |
| `MACOSX_DEPLOYMENT_TARGET` | 15.0 | Sequoia minimum |
| `SWIFT_STRICT_CONCURRENCY` | complete | Full data race safety |
| `ENABLE_HARDENED_RUNTIME` | YES | Required for notarization |
| `CODE_SIGN_IDENTITY` | "Developer ID Application" | Direct distribution |
| `PRODUCT_BUNDLE_IDENTIFIER` | com.yourteam.claudesync | Unique identifier |
| `INFOPLIST_KEY_LSUIElement` | YES | Menu bar only |
| `SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE` | YES | Swift 6.2 feature |

### Launch at Login Support

```swift
import ServiceManagement

extension ClaudeSyncApp {
    static func configureLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login configuration failed: \(error)")
        }
    }
    
    static var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
```

### Entitlements Summary

```xml
<!-- ClaudeSync.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- NOT sandboxed (needs rsync, ssh-keygen, filesystem access) -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
    
    <!-- Network (Bonjour discovery + SSH connections) -->
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    
    <!-- Subprocess execution compatibility -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

### Known Gotchas and Limitations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **LSUIElement + Settings** | No standard way to open preferences without Dock icon | Use `NSApp.activate()` + Window scene |
| **MenuBarExtra + multiple scenes** | Scene ordering affects behavior | Put MenuBarExtra first in body |
| **Login item registration** | `SMAppService` requires proper signing | Test with Developer ID cert |
| **Local network prompt** | User must approve local network access | Provide clear usage description |
| **Firewall prompt** | macOS firewall triggers on NWListener | Signing resolves for most users |
| **No Dock icon** | Users can't find app to relaunch if closed | Implement "launch at login" |

### Recommended Approach for ClaudeSync

- Use SwiftUI App lifecycle with `MenuBarExtra(.window)` as sole UI surface
- Set `LSUIElement = YES` to hide Dock icon
- Declare `_claudesync._tcp` in `NSBonjourServices`
- Provide clear `NSLocalNetworkUsageDescription`
- Do NOT sandbox -- app needs filesystem + subprocess access
- Use `SMAppService` for launch-at-login toggle
- Sign with Developer ID Application for direct distribution

---

## Summary: Architecture Decision Record

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| UI Framework | SwiftUI MenuBarExtra (.window) | Native, modern, minimal footprint |
| Peer Discovery | Network.framework (NWBrowser/NWListener) | Apple's recommended Bonjour API |
| File Watching | FSEvents (C API via actor wrapper) | Recursive, efficient, macOS-native |
| File Transfer | rsync (openrsync-compatible flags) | Battle-tested, incremental, SSH-native |
| Authentication | Ed25519 SSH keys | Modern, fast, industry standard |
| Concurrency | Swift 6 actors + AsyncStream | Data race safety, clean architecture |
| Distribution | Developer ID + notarytool | Direct distribution without App Store |
| Project Config | LSUIElement + non-sandboxed + Hardened Runtime | Menu bar utility requirements |

---

## Sources

### SwiftUI MenuBarExtra
- [Build a macOS menu bar utility in SwiftUI](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/)
- [Showing Settings from macOS Menu Bar Items](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- [MenuBarExtraAccess Library](https://github.com/orchetect/MenuBarExtraAccess)
- [Create a mac menu bar app in SwiftUI](https://sarunw.com/posts/swiftui-menu-bar-app/)

### Network.framework
- [NWListener | Apple Developer Documentation](https://developer.apple.com/documentation/network/nwlistener)
- [Advances in Networking, Part 2 - WWDC19](https://developer.apple.com/videos/play/wwdc2019/713/)
- [iOS/OSX Messaging Using Network Framework and Bonjour](https://boramaapps.medium.com/ios-osx-connections-with-network-framework-and-bonjour-service-7fa6130f5789)
- [NSBonjourServices | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices)

### FSEvents
- [File System Events | Apple Developer Documentation](https://developer.apple.com/documentation/coreservices/file_system_events)
- [FSEventsWrapper (Swift package)](https://github.com/Frizlab/FSEventsWrapper)
- [DispatchSource: Detecting changes in files](https://swiftrocks.com/dispatchsource-detecting-changes-in-files-and-folders-in-swift)

### rsync / openrsync
- [rsync replaced with openrsync on macOS Sequoia](https://derflounder.wordpress.com/2025/04/06/rsync-replaced-with-openrsync-on-macos-sequoia/)
- [What you should know about Apple's switch to openrsync](https://appleinsider.com/inside/macos-sequoia/tips/what-you-should-know-about-apples-switch-from-rsync-to-openrsync)
- [RSYNC Command reference (macOS)](https://ss64.com/mac/rsync.html)
- [How to Use rsync Over SSH](https://www.thelinuxvault.net/blog/how-to-use-rsync-over-ssh/)

### SSH Key Management
- [SSH Key Best Practices for 2025](https://www.brandonchecketts.com/archives/ssh-ed25519-key-best-practices-for-2025)
- [How to Configure SSH Key Authentication (2026)](https://oneuptime.com/blog/post/2026-01-24-configure-ssh-key-authentication/view)

### Swift 6 Concurrency
- [Approachable Concurrency in Swift 6.2](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)
- [@concurrent explained with code examples](https://www.avanderlee.com/concurrency/concurrent-explained-with-code-examples/)
- [Swift 6.2 Concurrency Changes](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)
- [Swift 6.2 Subprocess](https://mjtsai.com/blog/2025/10/30/swift-6-2-subprocess/)
- [swift-subprocess package](https://github.com/swiftlang/swift-subprocess)

### macOS Distribution
- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Complete Guide to Notarizing macOS Apps with notarytool](https://tonygo.tech/blog/2023/notarization-for-macos-app-with-notarytool)

### Xcode Configuration
- [LSUIElement | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [NSLocalNetworkUsageDescription | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
