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

    /// v1.2: when true, ClaudeSync auto-pairs with another Mac that
    /// publishes a matching record to iCloud Keychain (i.e. another Mac
    /// signed into the same Apple ID). The visual 6-digit code is
    /// skipped because same-Apple-ID is itself the auth factor.
    /// Defaults to true — set false to keep the v1.1 manual-confirm flow.
    public var autoPairSameAppleID: Bool

    public init(
        bandwidthLimitKBps: Int = 0,
        extraExcludes: [String: [String]] = [:],
        launchAtLogin: Bool = false,
        pairedPeer: PairedPeerRecord? = nil,
        autoPairSameAppleID: Bool = true
    ) {
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.extraExcludes = extraExcludes
        self.launchAtLogin = launchAtLogin
        self.pairedPeer = pairedPeer
        self.autoPairSameAppleID = autoPairSameAppleID
    }

    // Codable backwards compatibility — older preferences.json files don't
    // have `pairedPeer` / `autoPairSameAppleID`. Decode missing fields
    // with v1.2 defaults instead of failing.
    private enum CodingKeys: String, CodingKey {
        case bandwidthLimitKBps, extraExcludes, launchAtLogin, pairedPeer,
             autoPairSameAppleID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bandwidthLimitKBps = try c.decodeIfPresent(Int.self, forKey: .bandwidthLimitKBps) ?? 0
        self.extraExcludes = try c.decodeIfPresent([String: [String]].self,
                                                   forKey: .extraExcludes) ?? [:]
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.pairedPeer = try c.decodeIfPresent(PairedPeerRecord.self, forKey: .pairedPeer)
        self.autoPairSameAppleID = try c.decodeIfPresent(Bool.self,
                                                        forKey: .autoPairSameAppleID) ?? true
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
///
/// v1.1 (SEC-009): every persisted payload is signed with a per-machine
/// HMAC-SHA256 key kept at `~/.claudesync/.machine-key` (0o600). On load,
/// the on-disk signature is recomputed; mismatch ⇒ fall back to defaults
/// + log a tamper warning instead of honoring the modified file.
public actor PreferencesStore {

    public static let defaultURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/preferences.json")
    }()

    public enum LoadOutcome: Equatable, Sendable {
        case loaded
        case defaultsBecauseMissing
        case defaultsBecauseCorrupt
        case defaultsBecauseTampered
    }

    private let fileURL: URL
    private let logger: AppLogger
    private let integrity: PreferencesIntegrity
    private var cached: Preferences
    /// What happened on the most recent load attempt.
    public private(set) var lastLoadOutcome: LoadOutcome

    public init(fileURL: URL = PreferencesStore.defaultURL,
                logger: AppLogger = .shared) {
        self.fileURL = fileURL
        self.logger = logger
        self.integrity = PreferencesIntegrity(preferencesURL: fileURL,
                                              logger: logger)
        let (loaded, outcome) = Self.loadFromDisk(
            at: fileURL,
            integrity: PreferencesIntegrity(preferencesURL: fileURL, logger: logger),
            logger: logger
        )
        self.cached = loaded
        self.lastLoadOutcome = outcome
    }

    public func current() -> Preferences { cached }
    public func loadOutcome() -> LoadOutcome { lastLoadOutcome }

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
        // SEC-009: lock to owner-only AND write the HMAC sidecar so a
        // future load can detect tampering by another local user / process.
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: fileURL.path)
        do {
            let key = try integrity.loadOrCreateKey()
            try integrity.writeSignature(for: data, using: key)
        } catch {
            logger.warning("Could not write preferences integrity sig: \(error)",
                           category: "preferences")
        }
        logger.info("Preferences saved to \(fileURL.path)", category: "preferences")
    }

    nonisolated private static func loadFromDisk(
        at url: URL,
        integrity: PreferencesIntegrity,
        logger: AppLogger
    ) -> (Preferences, LoadOutcome) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (.default, .defaultsBecauseMissing)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.warning("Preferences read failed (\(error)) — using defaults",
                           category: "preferences")
            return (.default, .defaultsBecauseCorrupt)
        }

        // SEC-009: verify signature before trusting the payload.
        if FileManager.default.fileExists(atPath: integrity.signatureURL.path) {
            do {
                let key = try integrity.loadOrCreateKey()
                if !integrity.verify(payload: data, using: key) {
                    logger.warning("Preferences SIGNATURE MISMATCH — refusing to load tampered file. Falling back to defaults.",
                                   category: "preferences")
                    return (.default, .defaultsBecauseTampered)
                }
            } catch {
                logger.warning("Could not load integrity key: \(error)",
                               category: "preferences")
            }
        } else {
            // First-run after upgrade from v1.0.x — file exists but no
            // signature. Trust this once and the next save will sign it.
            logger.info("No integrity signature yet — first-run after upgrade",
                        category: "preferences")
        }

        do {
            let prefs = try JSONDecoder().decode(Preferences.self, from: data)
            return (prefs, .loaded)
        } catch {
            logger.warning("Preferences decode failed (\(error)) — using defaults",
                           category: "preferences")
            return (.default, .defaultsBecauseCorrupt)
        }
    }
}
