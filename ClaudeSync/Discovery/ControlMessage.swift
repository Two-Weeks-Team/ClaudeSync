import Foundation

/// Wire-level control plane message exchanged over the Bonjour TCP connection
/// between two ClaudeSync peers.
///
/// Phase 2+3 only needs the pairing and heartbeat messages; sync / conflict
/// payloads will land later. The enum is written so additional cases can be
/// added without breaking existing peers (older peers see and ignore unknown
/// `type` values).
///
/// Reference: TECHNICAL_SPEC §4 (Bonjour Discovery Protocol) lines 526-689.
public enum ControlMessage: Codable, Equatable, Sendable {
    case pairRequest(PairRequestPayload)
    case pairAccept(PairAcceptPayload)
    /// Initiator's final confirmation that the visual code matched. Until this
    /// arrives on the responder side, neither machine has committed the peer's
    /// key into authorized_keys (responder commits *only* on receiving this).
    case pairConfirm
    case pairReject(reason: String)
    case heartbeat(timestamp: Date)
    case disconnect(reason: String)
    case statusRequest

    // Custom Codable to keep the wire format flat: { "type": "...", ...payload }
    private enum CodingKeys: String, CodingKey {
        case type, reason, timestamp, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "pairRequest":
            self = .pairRequest(try c.decode(PairRequestPayload.self, forKey: .payload))
        case "pairAccept":
            self = .pairAccept(try c.decode(PairAcceptPayload.self, forKey: .payload))
        case "pairConfirm":
            self = .pairConfirm
        case "pairReject":
            self = .pairReject(reason: try c.decode(String.self, forKey: .reason))
        case "heartbeat":
            self = .heartbeat(timestamp: try c.decode(Date.self, forKey: .timestamp))
        case "disconnect":
            self = .disconnect(reason: try c.decode(String.self, forKey: .reason))
        case "statusRequest":
            self = .statusRequest
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown ControlMessage type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pairRequest(let p):
            try c.encode("pairRequest", forKey: .type)
            try c.encode(p, forKey: .payload)
        case .pairAccept(let p):
            try c.encode("pairAccept", forKey: .type)
            try c.encode(p, forKey: .payload)
        case .pairConfirm:
            try c.encode("pairConfirm", forKey: .type)
        case .pairReject(let reason):
            try c.encode("pairReject", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .heartbeat(let ts):
            try c.encode("heartbeat", forKey: .type)
            try c.encode(ts, forKey: .timestamp)
        case .disconnect(let reason):
            try c.encode("disconnect", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .statusRequest:
            try c.encode("statusRequest", forKey: .type)
        }
    }
}

public struct PairRequestPayload: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostname: String
    public let username: String
    public let publicKey: String           // Full OpenSSH ssh-ed25519 line
    public let publicKeyFingerprint: String
    public let protocolVersion: Int
    /// v1.0.1: initiator's local sshd port (CR-I1). Without this the responder
    /// could only assume port 22 and rsync from B→A would fail when A's sshd
    /// listens on a non-standard port.
    public let sshPort: UInt16

    public init(
        machineId: UUID, hostname: String, username: String,
        publicKey: String, publicKeyFingerprint: String,
        protocolVersion: Int = 1, sshPort: UInt16 = 22
    ) {
        self.machineId = machineId
        self.hostname = hostname
        self.username = username
        self.publicKey = publicKey
        self.publicKeyFingerprint = publicKeyFingerprint
        self.protocolVersion = protocolVersion
        self.sshPort = sshPort
    }

    private enum CodingKeys: String, CodingKey {
        case machineId, hostname, username, publicKey,
             publicKeyFingerprint, protocolVersion, sshPort
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.machineId = try c.decode(UUID.self, forKey: .machineId)
        self.hostname = try c.decode(String.self, forKey: .hostname)
        self.username = try c.decode(String.self, forKey: .username)
        self.publicKey = try c.decode(String.self, forKey: .publicKey)
        self.publicKeyFingerprint = try c.decode(String.self, forKey: .publicKeyFingerprint)
        self.protocolVersion = try c.decodeIfPresent(Int.self,
                                                     forKey: .protocolVersion) ?? 1
        self.sshPort = try c.decodeIfPresent(UInt16.self, forKey: .sshPort) ?? 22
    }
}

public struct PairAcceptPayload: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostname: String
    public let username: String
    public let publicKey: String
    public let publicKeyFingerprint: String
    public let sshPort: UInt16

    public init(
        machineId: UUID, hostname: String, username: String,
        publicKey: String, publicKeyFingerprint: String, sshPort: UInt16 = 22
    ) {
        self.machineId = machineId
        self.hostname = hostname
        self.username = username
        self.publicKey = publicKey
        self.publicKeyFingerprint = publicKeyFingerprint
        self.sshPort = sshPort
    }
}
