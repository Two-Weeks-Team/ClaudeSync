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
    /// v1.1 (SEC-005): when set, ssh is told to use this private
    /// known_hosts file with `StrictHostKeyChecking=yes` instead of the
    /// `accept-new` TOFU behavior. Empty string disables strict mode and
    /// falls back to the v1.0.x `accept-new` semantics.
    public let knownHostsPath: String
    /// v1.3 (SAFETY-001): when true, every push/pull is run with
    /// `--backup --backup-dir=<absolute>/.claudesync/trash/<job-id>/` so
    /// that files removed by `--delete` land in a quarantine instead of
    /// being immediately unlinked. The TrashJanitor actor sweeps stale
    /// entries on its own schedule. Disabled in some tests for output
    /// brevity but enabled by default in production.
    public let trashQuarantineEnabled: Bool

    public init(
        rsyncPath: String? = nil,
        sshKeyPath: String? = nil,
        bandwidthLimitKBps: Int = 0,
        userExtraExcludes: [SyncTarget: [String]] = [:],
        knownHostsPath: String = "",
        trashQuarantineEnabled: Bool = true
    ) {
        let detected = rsyncPath ?? Self.detectRsyncBinary()
        self.rsyncPath = detected
        self.isGNURsync = detected.contains("homebrew") || detected.contains("/opt/homebrew/")
        self.sshKeyPath = sshKeyPath ?? Self.defaultSSHKeyPath()
        self.bandwidthLimitKBps = max(0, bandwidthLimitKBps)
        self.userExtraExcludes = userExtraExcludes
        self.knownHostsPath = knownHostsPath
        self.trashQuarantineEnabled = trashQuarantineEnabled
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

        // SAFETY-001: rsync evaluates filter rules first-match-wins, so emit
        // the per-target protect rules BEFORE `--include`/`--exclude` block.
        // `P <subpath>***` keeps files under the subpath safe from --delete
        // while still allowing additions/modifications to flow through. The
        // `***` glob covers the directory itself + every descendant file
        // and directory (without it, only immediate children are matched).
        for sub in job.target.spec.protectFromDeleteSubpaths {
            let normalized = sub.hasSuffix("/") ? sub : sub + "/"
            args += ["--filter", "P \(normalized)***"]
        }

        // SAFETY-001: route every deletion through a quarantine directory
        // on the receiving side, so a mass-delete event (rm -rf, mtime
        // skew, propagated cleanup) is recoverable for the retention
        // window. Path is absolute because rsync does not shell-expand
        // backup-dir on the remote.
        if trashQuarantineEnabled, let trashDir = Self.trashDir(for: job, peer: peer) {
            args += ["--backup", "--backup-dir=\(trashDir)"]
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
        // v1.2.14: quote the *remote* path so its spaces survive ssh →
        // remote shell → wrapper → rsync. macOS Sequoia's openrsync
        // lacks `--protect-args` (which would pack args into rsync's
        // own protocol stream), so the remote path is delivered through
        // the remote shell — an unquoted `~/Library/Application
        // Support/Claude/` becomes three args ("server receiver mode
        // requires two argument" from openrsync). Single quotes solve
        // the space split BUT also suppress tilde expansion — `'~/x'`
        // creates a literal `~` directory on the remote. So keep the
        // leading `~/` outside the quotes (so the shell still expands
        // it) and single-quote the remainder. Reject any pre-existing
        // single quote in the path to defang quote-injection — none of
        // our target basePaths contain `'` but defence-in-depth.
        let remoteEncoded: String = {
            let safe = remoteTrailing.contains("'")
                ? remoteTrailing.replacingOccurrences(of: "'", with: "'\\''")
                : remoteTrailing
            if safe.hasPrefix("~/") {
                return "~/'\(safe.dropFirst(2))'"
            }
            if safe.hasPrefix("~") {
                // bare ~  →  ~''  (single quotes around empty remainder)
                return "~'\(safe.dropFirst(1))'"
            }
            return "'\(safe)'"
        }()
        switch job.direction {
        case .push:
            args.append(localTrailing)
            args.append("\(peer.sshAddress):\(remoteEncoded)")
        case .pull:
            args.append("\(peer.sshAddress):\(remoteEncoded)")
            args.append(localTrailing)
        }

        return args
    }

    // MARK: - Helpers

    func sshCommand(for peer: PeerEndpoint) -> String {
        // v1.1 (SEC-005): if we have a populated known_hosts (post-pairing),
        // require strict checking against it. Otherwise fall back to
        // accept-new for the very first pairing handshake.
        let hostKeyChecking: String
        var extra: [String] = []
        if !knownHostsPath.isEmpty {
            hostKeyChecking = "StrictHostKeyChecking=yes"
            extra += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
            extra += ["-o", "GlobalKnownHostsFile=/dev/null"]
        } else {
            hostKeyChecking = "StrictHostKeyChecking=accept-new"
        }
        let parts: [String] = [
            "ssh",
            "-i", sshKeyPath,
            "-o", "BatchMode=yes",
            "-o", hostKeyChecking,
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-p", String(peer.sshPort),
        ] + extra
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

    /// SAFETY-001: absolute trash directory on the **receiving** Mac, one
    /// fresh bucket per job. On push, the receiver is the peer Mac; we
    /// extract its username from `peer.sshAddress` (always `user@host` per
    /// the SSH transport contract) and assemble `/Users/<user>/.claudesync/
    /// trash/<job-id>/`. On pull, the receiver is local. Returns nil when
    /// the address can't be parsed — caller skips the backup flags rather
    /// than emitting a malformed argument.
    static func trashDir(for job: SyncJob,
                         peer: PeerEndpoint) -> String? {
        let bucket = job.id.uuidString
        switch job.direction {
        case .push:
            // SSH transport contract is `user@host`. A bare `host` (no @)
            // has no user we can root the trash under, so skip rather
            // than write to `/Users//.claudesync/...` (which would either
            // fail or land in the wrong place).
            guard peer.sshAddress.contains("@"),
                  let userPart = peer.sshAddress.split(separator: "@").first,
                  !userPart.isEmpty else {
                return nil
            }
            // macOS hosts always root home dirs at /Users/<user>; this
            // app is macOS-only so the assumption is safe.
            return "/Users/\(userPart)/.claudesync/trash/\(bucket)/"
        case .pull:
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".claudesync/trash/\(bucket)/")
                .path + "/"
        }
    }
}
