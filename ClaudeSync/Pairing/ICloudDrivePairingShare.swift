import Foundation

/// v1.2.1: shares pairing fingerprints across the user's Macs via iCloud
/// Drive when iCloud Keychain is unavailable (the common case for
/// ad-hoc-signed builds — `errSecMissingEntitlement`).
///
/// ## How it works
///
/// Each Mac writes its `PeerRecord` to a JSON file at
///   `~/Library/Mobile Documents/com.apple.CloudDocs/ClaudeSync/peers/<machineId>.json`
///
/// macOS's iCloud Drive sync agent fans the file out to every Mac
/// signed into the same Apple ID with iCloud Drive enabled — the same
/// way Notes / Pages / etc. do. **No iCloud entitlement needed**, no
/// paid Apple Developer Program needed, no Sandbox needed. Just
/// regular file system access into the user's home directory.
///
/// When a Bonjour peer is discovered, `lookup(machineId:)` reads the
/// corresponding file. If found AND the publicKeyFingerprint matches
/// the peer's wire-presented value, the visual 6-digit code is skipped
/// and pairing auto-confirms.
///
/// ## Trust model
///
/// Only Macs signed into the same Apple ID see each other's files via
/// iCloud Drive. The directory is hidden from Finder under iCloud Drive
/// (no special chmod needed) but the contents are NOT encrypted at
/// rest with a separate key — anyone with file system access on either
/// Mac under the user's account could read it. This is acceptable
/// because the file only contains public material (publicKey
/// fingerprint, hostname, username) — no private keys.
///
/// ## Graceful unavailability
///
/// If `~/Library/Mobile Documents/com.apple.CloudDocs/` doesn't exist,
/// the user has iCloud Drive disabled. `publish()` returns false and
/// the rest of the app falls back to the v1.1 visual-code flow.
public final class ICloudDrivePairingShare: @unchecked Sendable {

    public typealias PeerRecord = ICloudPairingShare.PeerRecord

    /// Standard macOS path to the user's iCloud Drive root.
    public static let cloudDocsRoot: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com.apple.CloudDocs",
                                    isDirectory: true)
    }()

    public let directory: URL
    private let logger: AppLogger

    public init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
                subpath: String = "ClaudeSync/peers",
                logger: AppLogger = .shared) {
        self.directory = homeDirectory
            .appendingPathComponent("Library/Mobile Documents/com.apple.CloudDocs",
                                    isDirectory: true)
            .appendingPathComponent(subpath, isDirectory: true)
        self.logger = logger
    }

    /// True if the iCloud Drive root exists and is writable. False on
    /// Macs without iCloud Drive enabled (e.g. not signed into iCloud,
    /// or iCloud Drive turned off in System Settings).
    public var isAvailable: Bool {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
                              .deletingLastPathComponent()  // .../com.apple.CloudDocs
        // Must exist AND be a directory we can write into.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDir),
              isDir.boolValue,
              fm.isWritableFile(atPath: parent.path) else {
            return false
        }
        return true
    }

    /// Publish (or update) our own record so other Macs on the same
    /// Apple ID can find us via iCloud Drive sync. Returns false when
    /// iCloud Drive is unavailable.
    @discardableResult
    public func publish(_ record: PeerRecord) -> Bool {
        guard isAvailable else {
            logger.info("iCloud Drive unavailable — visual-code flow will be used",
                        category: "icloud-pair")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let fileURL = recordURL(for: record.machineId)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: fileURL, options: .atomic)
            // 0o600 — only the user's processes should read.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            logger.info("Published pairing record to iCloud Drive (\(record.machineId.uuidString.prefix(8)))",
                        category: "icloud-pair")
            return true
        } catch {
            logger.warning("iCloud Drive publish failed: \(error)",
                           category: "icloud-pair")
            return false
        }
    }

    /// Look up another Mac's record by machineId.
    public func lookup(machineId: UUID) -> PeerRecord? {
        let fileURL = recordURL(for: machineId)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PeerRecord.self, from: data)
    }

    /// Enumerate every record currently in the shared directory (the
    /// local one + any synced down by iCloud Drive from other Macs).
    public func allRecords() -> [PeerRecord] {
        guard isAvailable,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return entries.compactMap { url -> PeerRecord? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PeerRecord.self, from: data)
        }
    }

    /// Remove our own record (called from "Forget paired peer" or on
    /// uninstall). Other-machine records are not touched.
    public func unpublish(machineId: UUID) {
        let fileURL = recordURL(for: machineId)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func recordURL(for machineId: UUID) -> URL {
        directory.appendingPathComponent("\(machineId.uuidString).json")
    }
}
