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

    public init(
        rsyncPath: String? = nil,
        sshKeyPath: String? = nil
    ) {
        let detected = rsyncPath ?? Self.detectRsyncBinary()
        self.rsyncPath = detected
        self.isGNURsync = detected.contains("homebrew") || detected.contains("/opt/homebrew/")
        self.sshKeyPath = sshKeyPath ?? Self.defaultSSHKeyPath()
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

        // Per-target excludes.
        for pattern in job.target.spec.excludePatterns {
            args += ["--exclude", pattern]
        }
        // Always-enforced security excludes.
        for pattern in IgnorePatterns.security {
            args += ["--exclude", pattern]
        }

        // Specific paths vs full sync.
        let basePath = job.target.spec.basePath.expandingTildeInPath
        if !job.isFullSync {
            // Use a files-from-style include filter set: include the listed
            // paths and their parent dirs, exclude everything else.
            for absolute in job.paths {
                let relative = relativePath(of: absolute, under: basePath) ?? absolute
                args += ["--include", relative]
            }
            args += ["--include", "*/", "--exclude", "*"]
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
