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

    /// Last successfully paired peer. v1.0.1: persisted across launches so
    /// the user doesn't need to re-pair on every restart (RCA-C3).
    public var pairedPeer: PairedPeerRecord?

    public init(
        bandwidthLimitKBps: Int = 0,
        extraExcludes: [String: [String]] = [:],
        launchAtLogin: Bool = false,
        pairedPeer: PairedPeerRecord? = nil
    ) {
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.extraExcludes = extraExcludes
        self.launchAtLogin = launchAtLogin
        self.pairedPeer = pairedPeer
    }

    // Codable backwards compatibility — older preferences.json files don't
    // have `pairedPeer`. Decode a missing field as nil instead of failing.
    private enum CodingKeys: String, CodingKey {
        case bandwidthLimitKBps, extraExcludes, launchAtLogin, pairedPeer
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bandwidthLimitKBps = try c.decodeIfPresent(Int.self, forKey: .bandwidthLimitKBps) ?? 0
        self.extraExcludes = try c.decodeIfPresent([String: [String]].self,
                                                   forKey: .extraExcludes) ?? [:]
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.pairedPeer = try c.decodeIfPresent(PairedPeerRecord.self, forKey: .pairedPeer)
    }
}

/// Persistable view of a paired peer. Mirrors PairingManager.PairedPeer but
/// lives in the Persistence layer so we don't import Pairing types into
/// Preferences.
public struct PairedPeerRecord: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostname: String
    public let username: String
    public let publicKeyFingerprint: String
    public let sshPort: UInt16
    public let pairedAt: Date

    public init(machineId: UUID, hostname: String, username: String,
                publicKeyFingerprint: String, sshPort: UInt16,
                pairedAt: Date = Date()) {
        self.machineId = machineId
        self.hostname = hostname
        self.username = username
        self.publicKeyFingerprint = publicKeyFingerprint
        self.sshPort = sshPort
        self.pairedAt = pairedAt
    }
}

extension Preferences {

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
        let fm = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(prefs)
        try data.write(to: fileURL, options: .atomic)
        // SEC-009 partial mitigation: lock file to owner-only so other local
        // user accounts on a shared Mac can't tamper with the paired peer
        // record or exclude patterns.
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: fileURL.path)
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
