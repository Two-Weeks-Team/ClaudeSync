import Foundation

/// Builds the rsync invocation for a `SyncJob`. Auto-detects whether the
/// safer `openrsync` (default `/usr/bin/rsync` on macOS Sequoia 15+) or the
/// more capable Homebrew GNU rsync 3.x at `/opt/homebrew/bin/rsync` is
/// available, and only emits flags compatible with the selected binary.
///
/// Reference: TECHNICAL_SPEC §3 (lines 220-313, 1976-2014).
public struct RsyncCommandBuilder: Sendable {

    public struct PeerEndpoint: Sendable {
        public let sshAddress: String     // e.g. "kim@MacBookAir.local"
        public let sshPort: UInt16
        public init(sshAddress: String, sshPort: UInt16 = 22) {
            self.sshAddress = sshAddress
            self.sshPort = sshPort
        }
    }

    public let rsyncPath: String
    public let isGNURsync: Bool
    public let sshKeyPath: String
    /// Maximum bandwidth in KiB/s. `0` means unlimited.
    public let bandwidthLimitKBps: Int
    /// User-supplied additional excludes per target, merged with the spec
    /// defaults and `IgnorePatterns.security`.
    public let userExtraExcludes: [SyncTarget: [String]]

    public init(
        rsyncPath: String? = nil,
        sshKeyPath: String? = nil,
        bandwidthLimitKBps: Int = 0,
        userExtraExcludes: [SyncTarget: [String]] = [:]
    ) {
        let detected = rsyncPath ?? Self.detectRsyncBinary()
        self.rsyncPath = detected
        self.isGNURsync = detected.contains("homebrew") || detected.contains("/opt/homebrew/")
        self.sshKeyPath = sshKeyPath ?? Self.defaultSSHKeyPath()
        self.bandwidthLimitKBps = max(0, bandwidthLimitKBps)
        self.userExtraExcludes = userExtraExcludes
    }

    /// Default `~/.claudesync/ssh/id_claudesync` path. Pulled into a static so
    /// the `init` default doesn't reach into the actor-isolated SSHKeyManager.
    public static func defaultSSHKeyPath() -> String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/ssh/id_claudesync").path
    }

    /// Prefer Homebrew rsync 3.x for the extra flags it supports, fall back
    /// to system `/usr/bin/rsync` (openrsync on macOS 15+).
    public static func detectRsyncBinary() -> String {
        let homebrew = "/opt/homebrew/bin/rsync"
        if FileManager.default.fileExists(atPath: homebrew) { return homebrew }
        return "/usr/bin/rsync"
    }

    /// Construct the full command-line for the given job.
    public func build(job: SyncJob, peer: PeerEndpoint, dryRun: Bool = false) -> [String] {
        var args: [String] = [rsyncPath]
        if dryRun { args += ["--dry-run", "--itemize-changes"] }

        // openrsync-safe core flags (TECHNICAL_SPEC L233-238).
        args += [
            "--archive",
            "--compress",
            "--delete",
            "--update",
            "--itemize-changes",
            "--partial",
            "--timeout=30",
            "-e", sshCommand(for: peer),
        ]

        // GNU-only enhancements when available.
        if isGNURsync {
            args += ["--delete-after"]
            args += ["--contimeout=10"]
        }

        // User-tunable bandwidth cap (rsync 3 + openrsync both honor --bwlimit).
        if bandwidthLimitKBps > 0 {
            args += ["--bwlimit=\(bandwidthLimitKBps)"]
        }

        // rsync evaluates filter rules **first match wins**. v1.0.1
        // (RCA-M2): emit `--include` rules BEFORE `--exclude` so that a
        // user-requested incremental sync of a specific file under a
        // normally-excluded directory still goes through. Within the
        // exclude block, security patterns must come first so a
        // user-supplied include can never shadow them (SEC-008).
        let basePath = job.target.spec.basePath.expandingTildeInPath

        // Includes (when targeting specific paths only).
        if !job.isFullSync {
            for absolute in job.paths {
                guard let relative = relativePath(of: absolute, under: basePath) else {
                    continue  // RCA P2 #10: silently drop paths outside basePath.
                }
                args += ["--include", relative]
            }
            // Allow rsync to descend through parent directories of the
            // included files, but block everything else.
            args += ["--include", "*/"]
        }

        // Excludes — security first, then per-target, then user extras.
        for pattern in IgnorePatterns.security {
            args += ["--exclude", pattern]
        }
        for pattern in job.target.spec.excludePatterns {
            args += ["--exclude", pattern]
        }
        for pattern in userExtraExcludes[job.target] ?? [] {
            args += ["--exclude", pattern]
        }
        if !job.isFullSync {
            args += ["--exclude", "*"]
        }

        let localTrailing = ensureTrailingSlash(basePath)
        let remoteTrailing = ensureTrailingSlash(job.target.spec.basePath)
        switch job.direction {
        case .push:
            args.append(localTrailing)
            args.append("\(peer.sshAddress):\(remoteTrailing)")
        case .pull:
            args.append("\(peer.sshAddress):\(remoteTrailing)")
            args.append(localTrailing)
        }

        return args
    }

    // MARK: - Helpers

    func sshCommand(for peer: PeerEndpoint) -> String {
        let parts: [String] = [
            "ssh",
            "-i", sshKeyPath,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-p", String(peer.sshPort),
        ]
        return parts.joined(separator: " ")
    }

    private func ensureTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? s : s + "/"
    }

    private func relativePath(of absolute: String, under base: String) -> String? {
        let baseSlashed = base.hasSuffix("/") ? base : base + "/"
        guard absolute.hasPrefix(baseSlashed) else { return nil }
        return String(absolute.dropFirst(baseSlashed.count))
    }
}
