import Foundation
import Security

/// v1.2: shares pairing fingerprints across the user's Macs via iCloud
/// Keychain so two ClaudeSync instances signed into the same Apple ID
/// auto-pair without the visual 6-digit code.
///
/// ## How it works
///
/// On launch, each Mac writes a generic-password keychain item with:
///   service:    `com.claudesync.pairing-handshake`
///   account:    its own machineId UUID
///   data:       JSON `{ machineId, hostname, username, sshPort,
///                       publicKeyFingerprint, sshHostKey, advertisedAt }`
///   synchronizable: true     ← causes iCloud Keychain to fan it out to
///                              every other Mac signed into the same
///                              Apple ID with iCloud Keychain enabled.
///
/// When a Bonjour peer is discovered, we look up an item keyed by the
/// peer's machineId. If found AND the publicKeyFingerprint in the
/// keychain matches what the peer is presenting over the wire, we
/// **skip the visual 6-digit code** because Apple's iCloud Keychain
/// E2E-encrypts the channel — same Apple ID is itself the
/// authentication factor.
///
/// ## Graceful fallback
///
/// `SecItemAdd` with `kSecAttrSynchronizable=true` may fail on:
///   * Macs not signed into iCloud
///   * Macs without iCloud Keychain enabled
///   * ad-hoc-signed apps in some macOS configurations
///
/// Any error from the Security framework falls back to the v1.1 visual
/// code flow — the user is never left without a way to pair.
public final class ICloudPairingShare: @unchecked Sendable {

    public static let serviceName = "com.claudesync.pairing-handshake"

    public struct PeerRecord: Codable, Equatable, Sendable {
        public let machineId: UUID
        public let hostname: String
        public let username: String
        public let sshPort: UInt16
        public let publicKeyFingerprint: String
        public let sshHostKey: String
        public let advertisedAt: Date

        public init(
            machineId: UUID, hostname: String, username: String,
            sshPort: UInt16, publicKeyFingerprint: String,
            sshHostKey: String, advertisedAt: Date = Date()
        ) {
            self.machineId = machineId
            self.hostname = hostname
            self.username = username
            self.sshPort = sshPort
            self.publicKeyFingerprint = publicKeyFingerprint
            self.sshHostKey = sshHostKey
            self.advertisedAt = advertisedAt
        }
    }

    public enum ShareError: Error, Sendable {
        case keychainUnavailable(OSStatus)
        case encodingFailed(String)
    }

    private let service: String
    private let logger: AppLogger

    public init(service: String = ICloudPairingShare.serviceName,
                logger: AppLogger = .shared) {
        self.service = service
        self.logger = logger
    }

    /// Publish (or update) our own record so other Macs on the same Apple
    /// ID can find us. Returns false if iCloud Keychain refused to store
    /// the item — the caller should fall back to the visual-code flow.
    @discardableResult
    public func publish(_ record: PeerRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else {
            logger.warning("Could not encode keychain record",
                           category: "icloud-pair")
            return false
        }
        let account = record.machineId.uuidString

        // Delete any prior version first — SecItemAdd doesn't update.
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String:   "ClaudeSync pairing — \(record.hostname)",
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecValueData as String:   data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            logger.info("Published pairing record to iCloud Keychain (\(account.prefix(8)))",
                        category: "icloud-pair")
            return true
        }
        // errSecMissingEntitlement (-34018), errSecAuthFailed (-25293),
        // errSecInteractionNotAllowed (-25308) all indicate iCloud
        // Keychain isn't usable in this context. Log once at info level
        // (not warning — this is expected on Macs without iCloud).
        logger.info("iCloud Keychain unavailable (status \(status)) — visual-code flow will be used",
                    category: "icloud-pair")
        return false
    }

    /// Look up another Mac's record by machineId. Returns nil if no item
    /// exists OR iCloud Keychain is unavailable.
    public func lookup(machineId: UUID) -> PeerRecord? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineId.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:  kCFBooleanTrue!,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PeerRecord.self, from: data)
    }

    /// Enumerate every record currently visible (the local one + any from
    /// other Macs that iCloud Keychain has synced down). Useful for
    /// debugging via `Settings → "Show iCloud-shared peers"`.
    public func allRecords() -> [PeerRecord] {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:  kCFBooleanTrue!,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String:  kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]] else {
            return []
        }
        return array.compactMap { dict in
            guard let data = dict[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(PeerRecord.self, from: data)
        }
    }

    /// Remove our own record (called from "Forget paired peer" or on
    /// uninstall). Other-machine records are not touched — those belong
    /// to the other Macs.
    public func unpublish(machineId: UUID) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineId.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
