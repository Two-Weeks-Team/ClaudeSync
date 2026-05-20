import Foundation

/// Top-level sync targets ClaudeSync can watch and sync. Phase 4 wires the
/// FSEvents-watched targets (`claudeConfig`, `claudeAppSupport`, `codexConfig`,
/// `projects`); Phase 6 will add the manifest-based package targets.
public enum SyncTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeConfig       // ~/.claude/
    case claudeAppSupport   // ~/Library/Application Support/Claude/
    case codexConfig        // ~/.codex/
    case projects           // ~/Documents/GitHub/

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeConfig:     return "Claude Code"
        case .claudeAppSupport: return "Claude Desktop"
        case .codexConfig:      return "Codex CLI"
        case .projects:         return "Projects"
        }
    }
}

/// Latency tier — different files have different urgency, so the file watcher
/// routes events into separate downstream queues. Reference: TECHNICAL_SPEC
/// §3 (3-Tier Sync Architecture), Momus R4.
public enum SyncTier: Int, Comparable, Codable, Sendable {
    case realtime = 0     // <3s, small critical files (settings, hooks, memory)
    case batched = 1      // 5-min accumulation (sessions, transcripts)
    case onDemand = 2     // user trigger / wake / schedule (project trees)

    public static func < (lhs: SyncTier, rhs: SyncTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SyncTargetSpec: Sendable {
    public let target: SyncTarget
    public let basePath: String                  // Tilde-expanded at runtime.
    public let watchPaths: [String]
    public let excludePatterns: [String]
    public let defaultTier: SyncTier
    /// Subpath prefixes (relative to basePath) that override the default tier.
    /// Used so e.g. `~/.claude/sessions/` falls into `.batched` instead of
    /// the rest of `~/.claude/` which is `.realtime`.
    public let heavySubpaths: [String]
    public let heavySubpathTier: SyncTier
    public let supportsProjectIgnoreFile: Bool
    /// v1.3 (SAFETY-001): subpath prefixes (relative to basePath) whose
    /// contents are protected from `--delete` propagation. Used so that
    /// when one Mac's Claude Code runs its periodic cleanup of
    /// `file-history/`, `sessions/`, `backups/` etc., the resulting
    /// unlinks don't propagate to the peer Mac and wipe its history.
    /// Implemented via rsync `--filter='P <subpath>***'` rules, which
    /// both openrsync (macOS 15+) and GNU rsync 3.x honor.
    public let protectFromDeleteSubpaths: [String]

    public init(
        target: SyncTarget, basePath: String, watchPaths: [String],
        excludePatterns: [String], defaultTier: SyncTier,
        heavySubpaths: [String] = [], heavySubpathTier: SyncTier = .batched,
        supportsProjectIgnoreFile: Bool = false,
        protectFromDeleteSubpaths: [String] = []
    ) {
        self.target = target
        self.basePath = basePath
        self.watchPaths = watchPaths
        self.excludePatterns = excludePatterns
        self.defaultTier = defaultTier
        self.heavySubpaths = heavySubpaths
        self.heavySubpathTier = heavySubpathTier
        self.supportsProjectIgnoreFile = supportsProjectIgnoreFile
        self.protectFromDeleteSubpaths = protectFromDeleteSubpaths
    }

    /// Resolve a relative path within this target into the appropriate tier.
    public func tier(forRelativePath relative: String) -> SyncTier {
        for prefix in heavySubpaths where relative.hasPrefix(prefix) {
            return heavySubpathTier
        }
        return defaultTier
    }
}

public extension SyncTarget {
    /// The canonical spec for each target. Paths use tilde notation so the
    /// caller can decide when to expand (FSEvents wants absolute paths).
    var spec: SyncTargetSpec {
        switch self {
        case .claudeConfig:
            return SyncTargetSpec(
                target: .claudeConfig,
                basePath: "~/.claude",
                watchPaths: ["~/.claude"],
                excludePatterns: [
                    ".claudesync/",
                    "statsig/",
                    "*.lock", "*.tmp",
                    "credentials.json",
                    "oauth_token*",
                    // SAFETY-001: never propagate Claude Code's cleanup marker
                    // — its mtime is pure local state and propagating it would
                    // synchronize cleanup cadence across both Macs.
                    ".last-cleanup",
                ],
                defaultTier: .realtime,
                heavySubpaths: ["sessions/", "transcripts/"],
                heavySubpathTier: .batched,
                protectFromDeleteSubpaths: [
                    // Append-only logs / version history / backups whose
                    // entries Claude Code prunes on its own (~7-30 day
                    // retention). Each Mac runs its own cleanup; if one
                    // Mac's cleanup unlinks a file, that unlink must NOT
                    // propagate to the peer — the peer's retention window
                    // is independent.
                    "sessions/",
                    "transcripts/",
                    "projects/",
                    "file-history/",
                    "backups/",
                    "shell-snapshots/",
                ]
            )
        case .claudeAppSupport:
            return SyncTargetSpec(
                target: .claudeAppSupport,
                basePath: "~/Library/Application Support/Claude",
                watchPaths: ["~/Library/Application Support/Claude"],
                excludePatterns: [
                    "Cache/", "GPUCache/", "blob_storage/", "Crashpad/",
                    "DawnCache/", "Local Storage/", "Session Storage/",
                    "Service Worker/", "WebStorage/", "*.log",
                ],
                defaultTier: .realtime
            )
        case .codexConfig:
            return SyncTargetSpec(
                target: .codexConfig,
                basePath: "~/.codex",
                watchPaths: ["~/.codex"],
                excludePatterns: ["*.log", "cache/", "*.tmp"],
                defaultTier: .realtime
            )
        case .projects:
            return SyncTargetSpec(
                target: .projects,
                basePath: "~/Documents/GitHub",
                watchPaths: ["~/Documents/GitHub"],
                excludePatterns: [
                    "node_modules/", ".git/objects/", ".git/pack/",
                    ".next/", ".nuxt/", "dist/", "build/", ".build/",
                    "DerivedData/", "Pods/", ".gradle/", "target/", "vendor/",
                    "__pycache__/", "*.pyc", ".venv/", "venv/",
                    ".env.local", ".env.*.local",
                    "*.o", "*.a", "*.dylib", "*.so",
                    ".DS_Store", "Thumbs.db", "*.swp", "*.swo",
                ],
                defaultTier: .onDemand,
                supportsProjectIgnoreFile: true
            )
        }
    }
}

// MARK: - Path expansion helper

public extension String {
    /// Expand a leading `~` to the home directory. Mirrors NSString's
    /// `expandingTildeInPath` but is Sendable-friendly.
    var expandingTildeInPath: String {
        guard hasPrefix("~") else { return self }
        let rest = String(self.dropFirst())
        return NSHomeDirectory() + rest
    }
}
