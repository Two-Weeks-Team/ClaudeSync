import Foundation

/// User-tunable settings persisted to `~/.claudesync/preferences.json`.
///
/// The model is small and deliberately schema-stable: every field has a
/// default so deserializing an older file still works after an upgrade.
public struct Preferences: Codable, Equatable, Sendable {

    /// Maximum bandwidth, in KiB/s, passed to rsync via `--bwlimit`.
    /// `0` means unlimited.
    public var bandwidthLimitKBps: Int

    /// Per-target additional exclude patterns the user has added.
    /// Stored using the SyncTarget raw value as the key so the JSON file is
    /// readable.
    public var extraExcludes: [String: [String]]

    /// Whether the user has opted into auto-launch on login.
    public var launchAtLogin: Bool

    public init(
        bandwidthLimitKBps: Int = 0,
        extraExcludes: [String: [String]] = [:],
        launchAtLogin: Bool = false
    ) {
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.extraExcludes = extraExcludes
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = Preferences()

    /// Synchronous load helper for use during AppEnvironment initialization
    /// where actor isolation isn't yet established. Returns defaults on any
    /// error.
    public static func loadInitialSync(from url: URL) -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data)
        else {
            return .default
        }
        return prefs
    }

    public func extraExcludes(for target: SyncTarget) -> [String] {
        extraExcludes[target.rawValue] ?? []
    }

    public func ignorePatterns() -> IgnorePatterns {
        var perTargetExtra: [SyncTarget: [String]] = [:]
        for target in SyncTarget.allCases {
            let extras = extraExcludes(for: target)
            if !extras.isEmpty {
                perTargetExtra[target] = extras
            }
        }
        return IgnorePatterns(userExtra: perTargetExtra)
    }
}

/// File-backed preferences store. Loading is best-effort: a missing or
/// malformed file silently falls back to defaults so the app never refuses
/// to launch because of corrupted JSON.
public actor PreferencesStore {

    public static let defaultURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/preferences.json")
    }()

    private let fileURL: URL
    private let logger: AppLogger
    private var cached: Preferences

    public init(fileURL: URL = PreferencesStore.defaultURL,
                logger: AppLogger = .shared) {
        self.fileURL = fileURL
        self.logger = logger
        self.cached = Self.loadFromDisk(at: fileURL, logger: logger)
    }

    public func current() -> Preferences { cached }

    public func update(_ transform: (inout Preferences) -> Void) throws {
        var copy = cached
        transform(&copy)
        try persist(copy)
        cached = copy
    }

    public func replace(_ preferences: Preferences) throws {
        try persist(preferences)
        cached = preferences
    }

    private func persist(_ prefs: Preferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(prefs)
        try data.write(to: fileURL, options: .atomic)
        logger.info("Preferences saved to \(fileURL.path)", category: "preferences")
    }

    nonisolated private static func loadFromDisk(
        at url: URL,
        logger: AppLogger
    ) -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Preferences.self, from: data)
        } catch {
            logger.warning("Preferences load failed (\(error)) — using defaults",
                           category: "preferences")
            return .default
        }
    }
}
