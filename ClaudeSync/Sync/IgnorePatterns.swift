import Foundation

/// rsync-style exclude patterns evaluated *before* a sync job is queued.
/// The same patterns will later be passed to rsync via `--exclude`, but
/// pre-filtering at the FileWatcher layer keeps the job queue lean and
/// avoids needless rsync invocations when an ignored file changes.
public struct IgnorePatterns: Sendable {

    /// Files that must NEVER be synced regardless of user configuration.
    /// Mirrors `SecurityPolicy.absolutelyExcluded` from TECHNICAL_SPEC §10.
    public static let security: [String] = [
        "credentials.json",
        "oauth_token*",
        ".env.local",
        ".env.*.local",
        "id_rsa", "id_ed25519",
        "*.pem", "*.key",
        "keychain-*",
        ".netrc",
        ".npmrc", ".pypirc",
    ]

    /// Cross-target defaults (rarely useful to sync anywhere).
    public static let global: [String] = [
        ".DS_Store",
        "Thumbs.db",
        "*.swp", "*.swo",
        "*.tmp",
    ]

    public let security: [String]
    public let global: [String]
    public let perTarget: [SyncTarget: [String]]
    public let userExtra: [SyncTarget: [String]]

    public init(
        security: [String] = IgnorePatterns.security,
        global: [String] = IgnorePatterns.global,
        perTarget: [SyncTarget: [String]] = [:],
        userExtra: [SyncTarget: [String]] = [:]
    ) {
        self.security = security
        self.global = global
        self.perTarget = perTarget.isEmpty ? Self.defaultPerTarget : perTarget
        self.userExtra = userExtra
    }

    /// Default per-target patterns derived from each `SyncTargetSpec`.
    public static var defaultPerTarget: [SyncTarget: [String]] {
        var dict: [SyncTarget: [String]] = [:]
        for target in SyncTarget.allCases {
            dict[target] = target.spec.excludePatterns
        }
        return dict
    }

    /// Returns true if the given absolute path should be ignored.
    /// Matching is glob-style:
    ///   * `foo/`    — any descendant under a `foo` directory
    ///   * `*.log`   — any path whose last component matches `*.log`
    ///   * `foo`     — exact basename match anywhere in the path
    ///   * `foo*`    — basename prefix match anywhere
    public func shouldIgnore(absolutePath: String, target: SyncTarget) -> Bool {
        let components = (absolutePath as NSString).pathComponents
        let basename = components.last ?? absolutePath

        let allPatterns = security + global + (perTarget[target] ?? []) + (userExtra[target] ?? [])

        for pattern in allPatterns {
            if Self.matches(pattern: pattern, basename: basename, components: components) {
                return true
            }
        }
        return false
    }

    // MARK: - Glob

    static func matches(pattern: String, basename: String, components: [String]) -> Bool {
        if pattern.hasSuffix("/") {
            // Directory pattern — any path component equal to the prefix.
            let dirName = String(pattern.dropLast())
            return components.contains(where: { Self.fnmatch(pattern: dirName, name: $0) })
        }
        // File pattern — match against basename (last component) and any component.
        if Self.fnmatch(pattern: pattern, name: basename) { return true }
        for component in components {
            if Self.fnmatch(pattern: pattern, name: component) { return true }
        }
        return false
    }

    /// Tiny shell-style wildcard matcher supporting `*` and `?` (case-sensitive).
    /// Sufficient for our gitignore-flavoured patterns; we don't need character
    /// classes or alternation.
    static func fnmatch(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        return matchHelper(p: p, pi: 0, n: n, ni: 0)
    }

    private static func matchHelper(p: [Character], pi: Int, n: [Character], ni: Int) -> Bool {
        if pi == p.count { return ni == n.count }
        let pc = p[pi]
        if pc == "*" {
            // `*` matches zero or more of anything (within a single component).
            if pi + 1 == p.count { return true }
            for k in ni...n.count {
                if matchHelper(p: p, pi: pi + 1, n: n, ni: k) { return true }
            }
            return false
        }
        if ni == n.count { return false }
        if pc == "?" || pc == n[ni] {
            return matchHelper(p: p, pi: pi + 1, n: n, ni: ni + 1)
        }
        return false
    }
}
