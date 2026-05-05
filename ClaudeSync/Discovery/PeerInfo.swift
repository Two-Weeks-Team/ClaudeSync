import Foundation
import Network

/// Snapshot of a peer ClaudeSync instance discovered via Bonjour. Bonjour TXT
/// records are decoded into the typed fields below.
public struct PeerInfo: Identifiable, Equatable, Sendable {
    public var id: UUID { machineId }

    public let machineId: UUID
    public let hostname: String
    public let username: String
    public let sshPort: UInt16
    public let publicKeyFingerprint: String?
    public let isPaired: Bool
    public var endpointDescription: String

    /// SSH-style address suitable for rsync, e.g. `kim@MacBookAir.local`.
    public var sshAddress: String { "\(username)@\(hostname).local" }

    public init(machineId: UUID, hostname: String, username: String,
                sshPort: UInt16, publicKeyFingerprint: String?,
                isPaired: Bool, endpointDescription: String) {
        self.machineId = machineId
        self.hostname = hostname
        self.username = username
        self.sshPort = sshPort
        self.publicKeyFingerprint = publicKeyFingerprint
        self.isPaired = isPaired
        self.endpointDescription = endpointDescription
    }

    // MARK: - TXT record decoding

    /// Decode a `NWTXTRecord` into a typed `PeerInfo`. Returns `nil` if the
    /// required keys are missing or malformed (e.g. peer running a future
    /// protocol version we don't understand).
    public static func decode(txt: NWTXTRecord, endpointDescription: String) -> PeerInfo? {
        guard let machineIdStr = txt[BonjourKeys.machineId],
              let machineId = UUID(uuidString: machineIdStr),
              let hostname = txt[BonjourKeys.hostname],
              let username = txt[BonjourKeys.username],
              let portStr = txt[BonjourKeys.sshPort],
              let port = UInt16(portStr) else {
            return nil
        }
        let pairedStr = txt[BonjourKeys.paired] ?? "0"
        return PeerInfo(
            machineId: machineId,
            hostname: hostname,
            username: username,
            sshPort: port,
            publicKeyFingerprint: txt[BonjourKeys.publicKeyFP],
            isPaired: pairedStr == "1",
            endpointDescription: endpointDescription
        )
    }
}

/// Canonical TXT record keys advertised in the `_claudesync._tcp` Bonjour
/// service. Keys are lower-case alphanumerics — Bonjour TXT records are
/// case-sensitive but conventionally lower.
public enum BonjourKeys {
    public static let version       = "v"
    public static let machineId     = "mid"
    public static let hostname      = "host"
    public static let username      = "user"
    public static let sshPort       = "sport"
    public static let paired        = "paired"
    public static let publicKeyFP   = "fp"
}

public enum PeerDiscoveryError: Error, Sendable {
    case alreadyRunning
    case listenerSetupFailed(String)
    case browserSetupFailed(String)
    case noEndpointForPeer(UUID)
}
