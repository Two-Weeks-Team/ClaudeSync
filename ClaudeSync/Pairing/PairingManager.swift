import Foundation

/// Coordinates the pairing handshake between the local machine and a peer
/// over a `PeerChannel`. The protocol is symmetric — the same actor runs on
/// both sides, transitioning roles based on which message arrives first.
///
/// The 6-digit visual confirmation code (``PairingCodeGenerator``) is computed
/// once both public keys are exchanged. *Neither side commits the peer's key
/// to authorized_keys until both users have confirmed the code matches.*
///
/// ### Sequence (initiator A, responder B)
///
/// 1. **A.initiate()** → A sends `pairRequest(A.pubkey, A.identity)` and
///    enters `.sentPairRequest`.
/// 2. **B** receives `pairRequest`, computes code, transitions to
///    `.receivedPairRequest(code)`, surfaces code + identity to the UI.
/// 3. **B.acceptPendingRequest()** → B sends `pairAccept(B.pubkey, B.identity)`
///    and enters `.sentPairAccept`. *No key installed yet on B.*
/// 4. **A** receives `pairAccept`, computes the same code, transitions to
///    `.receivedPairAccept(code)`, surfaces code to the UI.
/// 5. **A.confirmCode()** → A installs B's key, sends `pairConfirm`, enters
///    `.completed(pairedPeer)`.
/// 6. **B** receives `pairConfirm`, installs A's key, enters `.completed`.
///
/// Either side may call ``reject(reason:)`` at any pre-completion step; the
/// other side transitions to `.rejected`. If A rejects after step 4, B has not
/// yet installed anything so cleanup is unnecessary.
public actor PairingManager {

    // MARK: - Types

    public struct LocalIdentity: Equatable, Sendable {
        public let machineId: UUID
        public let hostname: String
        public let username: String
        public let sshPort: UInt16

        public init(machineId: UUID, hostname: String, username: String, sshPort: UInt16 = 22) {
            self.machineId = machineId
            self.hostname = hostname
            self.username = username
            self.sshPort = sshPort
        }
    }

    public struct PairedPeer: Equatable, Sendable {
        public let machineId: UUID
        public let hostname: String
        public let username: String
        public let publicKey: String
        public let publicKeyFingerprint: String
        public let sshPort: UInt16
        /// v1.1 (SEC-005): peer's SSH host key for known_hosts pre-pop.
        /// Empty when older peer didn't ship it or local lookup failed.
        public var sshHostPublicKey: String = ""
    }

    public enum State: Equatable, Sendable {
        case idle

        // Initiator path
        case sentPairRequest
        case receivedPairAccept(PairAcceptPayload, code: String)

        // Responder path
        case receivedPairRequest(PairRequestPayload, code: String)
        case sentPairAccept(PairRequestPayload, code: String)

        // Terminal
        case completed(PairedPeer)
        case rejected(reason: String)
        case failed(message: String)

        public var isTerminal: Bool {
            switch self {
            case .completed, .rejected, .failed: return true
            default:                              return false
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case stateChanged(State)
    }

    public enum PairingError: Error, Sendable, Equatable {
        case invalidStateForAction(currentState: String, action: String)
        case sendFailed(String)
        case keyManagementFailed(String)
        case codeMismatch
        case clockSkewTooLarge(seconds: Double)
        case tooManyAttempts
    }

    /// v1.1 (RCA-M9): if the peer's wall-clock differs from ours by more
    /// than this many seconds, we refuse the pairing rather than risk
    /// `newer-wins` ConflictResolver picking the wrong file later.
    public static let maxClockSkewSeconds: Double = 30
    /// v1.1 (SEC-003): a single PairingManager session accepts at most one
    /// pairRequest. Repeated attempts from the same channel are dropped to
    /// prevent brute force iteration over the 1M code space.
    public static let maxPairRequestsPerSession: Int = 1

    // MARK: - Dependencies

    private let channel: PeerChannel
    private let sshKeys: SSHKeyManager
    private let identity: LocalIdentity
    private let logger = AppLogger.shared

    // MARK: - State

    public private(set) var state: State = .idle
    private var listeningTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var localPubkeyBytes: Data?
    private var localPubkeyLine: String?
    private var localPubkeyFingerprint: String?
    /// v1.1 (SEC-003): nonces for the current session. Set once per
    /// initiate()/start().
    private var localNonce: Data = Data()
    private var peerNonce: Data = Data()
    /// v1.1 (SEC-003): count of pairRequest messages we've handled in
    /// this session. Anything past `maxPairRequestsPerSession` is dropped.
    private var pairRequestCount: Int = 0

    // MARK: - Init

    public init(channel: PeerChannel, sshKeys: SSHKeyManager, identity: LocalIdentity) {
        self.channel = channel
        self.sshKeys = sshKeys
        self.identity = identity
    }

    // MARK: - Public API

    /// Start listening for incoming control messages. Idempotent.
    /// Call before any user actions; both initiator and responder need it.
    public func start() async throws {
        if listeningTask != nil { return }
        try await ensureLocalKeyMaterial()
        if localNonce.isEmpty {
            localNonce = PairingCodeGenerator.newNonce()
        }

        let stream = channel.incomingMessages()
        listeningTask = Task { [weak self] in
            for await msg in stream {
                guard let self else { break }
                await self.handle(message: msg)
            }
        }
    }

    /// Initiator entry point: send `pairRequest` with our public key.
    public func initiate() async throws {
        try await start()
        guard state == .idle else {
            throw PairingError.invalidStateForAction(
                currentState: String(describing: state), action: "initiate"
            )
        }
        guard let pubkeyLine = localPubkeyLine,
              let fingerprint = localPubkeyFingerprint else {
            throw PairingError.keyManagementFailed("local key material not loaded")
        }

        let payload = PairRequestPayload(
            machineId: identity.machineId,
            hostname: identity.hostname,
            username: identity.username,
            publicKey: pubkeyLine,
            publicKeyFingerprint: fingerprint,
            sshPort: identity.sshPort,
            clockUnixSeconds: Date().timeIntervalSince1970,
            nonceHex: PairingCodeGenerator.hexEncode(localNonce)
        )
        do {
            try await channel.send(.pairRequest(payload))
        } catch {
            await transition(to: .failed(message: "send pairRequest failed: \(error)"))
            throw PairingError.sendFailed(String(describing: error))
        }
        await transition(to: .sentPairRequest)
    }

    /// Responder entry point: the user has approved the pending pairRequest.
    /// Sends `pairAccept` with our public key. Does NOT install the peer key
    /// yet — that happens only when `pairConfirm` arrives from the initiator.
    public func acceptPendingRequest() async throws {
        guard case .receivedPairRequest(let req, let code) = state else {
            throw PairingError.invalidStateForAction(
                currentState: String(describing: state), action: "acceptPendingRequest"
            )
        }

        guard let pubkeyLine = localPubkeyLine,
              let fingerprint = localPubkeyFingerprint else {
            throw PairingError.keyManagementFailed("local key material not loaded")
        }
        // v1.1 (SEC-005): try to read this Mac's SSH host key so the
        // initiator can pre-populate known_hosts. Empty string on failure
        // is fine — initiator just stays on accept-new TOFU for that host.
        let hostKey = (try? Self.readLocalSshHostKey()) ?? ""
        let payload = PairAcceptPayload(
            machineId: identity.machineId,
            hostname: identity.hostname,
            username: identity.username,
            publicKey: pubkeyLine,
            publicKeyFingerprint: fingerprint,
            sshPort: identity.sshPort,
            clockUnixSeconds: Date().timeIntervalSince1970,
            nonceHex: PairingCodeGenerator.hexEncode(localNonce),
            sshHostPublicKey: hostKey
        )
        do {
            try await channel.send(.pairAccept(payload))
        } catch {
            await transition(to: .failed(message: "send pairAccept failed: \(error)"))
            throw PairingError.sendFailed(String(describing: error))
        }
        await transition(to: .sentPairAccept(req, code: code))
    }

    /// Initiator confirms that the code displayed on both screens matches.
    /// Installs the peer's key into authorized_keys and sends `pairConfirm`.
    public func confirmCode() async throws {
        guard case .receivedPairAccept(let accept, _) = state else {
            throw PairingError.invalidStateForAction(
                currentState: String(describing: state), action: "confirmCode"
            )
        }

        do {
            try await sshKeys.installPeerKey(accept.publicKey)
        } catch {
            await transition(to: .failed(message: "installPeerKey failed: \(error)"))
            throw PairingError.keyManagementFailed(String(describing: error))
        }
        do {
            try await channel.send(.pairConfirm)
        } catch {
            // Best effort: roll back the just-installed key.
            try? await sshKeys.removePeerKey(matchingComment: "claudesync@\(accept.hostname)")
            await transition(to: .failed(message: "send pairConfirm failed: \(error)"))
            throw PairingError.sendFailed(String(describing: error))
        }

        let paired = PairedPeer(
            machineId: accept.machineId,
            hostname: accept.hostname,
            username: accept.username,
            publicKey: accept.publicKey,
            publicKeyFingerprint: accept.publicKeyFingerprint,
            sshPort: accept.sshPort,
            sshHostPublicKey: accept.sshHostPublicKey
        )
        await transition(to: .completed(paired))
    }

    /// Either side can reject from any pre-completion state.
    public func reject(reason: String) async throws {
        switch state {
        case .completed, .rejected, .failed:
            throw PairingError.invalidStateForAction(
                currentState: String(describing: state), action: "reject"
            )
        default: break
        }
        do {
            try await channel.send(.pairReject(reason: reason))
        } catch {
            // Even if send fails we still consider the local state rejected.
            logger.warning("send pairReject failed: \(error)", category: "pairing")
        }
        await transition(to: .rejected(reason: reason))
    }

    /// Stream of state-change events. Suitable for SwiftUI to observe.
    public func events() -> AsyncStream<Event> {
        AsyncStream<Event> { continuation in
            self.eventContinuation = continuation
            continuation.yield(.stateChanged(self.state))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearEventContinuation() }
            }
        }
    }

    /// Shut down. Cancels listening, closes the channel.
    public func cancel() async {
        listeningTask?.cancel()
        listeningTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        await channel.close()
    }

    // MARK: - Incoming dispatch

    private func handle(message: ControlMessage) async {
        switch message {
        case .pairRequest(let req):
            await handlePairRequest(req)
        case .pairAccept(let accept):
            await handlePairAccept(accept)
        case .pairConfirm:
            await handlePairConfirm()
        case .pairReject(let reason):
            await transition(to: .rejected(reason: reason))
        case .disconnect(let reason):
            // Treat peer-initiated disconnect mid-handshake as failure.
            if !state.isTerminal {
                await transition(to: .failed(message: "peer disconnected: \(reason)"))
            }
        case .heartbeat, .statusRequest:
            // Out of band for pairing; ignore.
            break
        }
    }

    private func handlePairRequest(_ req: PairRequestPayload) async {
        guard state == .idle else {
            logger.warning("dropping pairRequest in state \(String(describing: state))",
                           category: "pairing")
            return
        }
        // v1.1 (SEC-003): a single session accepts at most one pairRequest.
        pairRequestCount += 1
        if pairRequestCount > Self.maxPairRequestsPerSession {
            await transition(to: .failed(
                message: "too many pair attempts on this session"
            ))
            return
        }
        // v1.1 (RCA-M9): clock-skew check first — it's the cheapest gate
        // and protects ConflictResolver's newer-wins from a peer whose
        // wall-clock has drifted, regardless of key validity.
        if req.clockUnixSeconds > 0 {
            let skew = abs(Date().timeIntervalSince1970 - req.clockUnixSeconds)
            if skew > Self.maxClockSkewSeconds {
                await transition(to: .failed(
                    message: "peer clock skew \(Int(skew))s exceeds limit"
                ))
                return
            }
        }
        // v1.0.1: refuse a request whose key we cannot parse, or while our
        // own local key material isn't loaded yet. Falling back to empty Data
        // would let two peers compute the SAME code from empty bytes (and
        // accept the pairing), which is a security hole.
        guard let peerKeyBytes = try? Self.parsePublicKeyBytes(from: req.publicKey),
              !peerKeyBytes.isEmpty else {
            await transition(to: .failed(message: "peer public key is malformed"))
            return
        }
        guard let myKeyBytes = localPubkeyBytes, !myKeyBytes.isEmpty else {
            await transition(to: .failed(message: "local public key not loaded"))
            return
        }
        // v1.1 (SEC-003): mix in both nonces. peer's nonce is on the wire;
        // ours was generated in start(). Initiator key is *peer*'s here
        // (they sent the pairRequest), so ordering is (peer, us).
        peerNonce = PairingCodeGenerator.hexDecode(req.nonceHex)
        let code = PairingCodeGenerator.generateCode(
            initiatorPublicKey: peerKeyBytes,
            responderPublicKey: myKeyBytes,
            initiatorNonce: peerNonce,
            responderNonce: localNonce
        )
        await transition(to: .receivedPairRequest(req, code: code))
    }

    private func handlePairAccept(_ accept: PairAcceptPayload) async {
        guard state == .sentPairRequest else {
            logger.warning("dropping pairAccept in state \(String(describing: state))",
                           category: "pairing")
            return
        }
        guard let peerKeyBytes = try? Self.parsePublicKeyBytes(from: accept.publicKey),
              !peerKeyBytes.isEmpty else {
            await transition(to: .failed(message: "peer public key is malformed"))
            return
        }
        guard let myKeyBytes = localPubkeyBytes, !myKeyBytes.isEmpty else {
            await transition(to: .failed(message: "local public key not loaded"))
            return
        }
        if accept.clockUnixSeconds > 0 {
            let skew = abs(Date().timeIntervalSince1970 - accept.clockUnixSeconds)
            if skew > Self.maxClockSkewSeconds {
                await transition(to: .failed(
                    message: "peer clock skew \(Int(skew))s exceeds limit"
                ))
                return
            }
        }
        // v1.1 (SEC-003): we were the initiator, peer is the responder.
        // Order is (us, peer) for both keys and nonces.
        peerNonce = PairingCodeGenerator.hexDecode(accept.nonceHex)
        let code = PairingCodeGenerator.generateCode(
            initiatorPublicKey: myKeyBytes,
            responderPublicKey: peerKeyBytes,
            initiatorNonce: localNonce,
            responderNonce: peerNonce
        )
        await transition(to: .receivedPairAccept(accept, code: code))
    }

    private func handlePairConfirm() async {
        guard case .sentPairAccept(let req, _) = state else {
            logger.warning("dropping pairConfirm in state \(String(describing: state))",
                           category: "pairing")
            return
        }
        do {
            try await sshKeys.installPeerKey(req.publicKey)
        } catch {
            await transition(to: .failed(message: "installPeerKey failed: \(error)"))
            return
        }

        let paired = PairedPeer(
            machineId: req.machineId,
            hostname: req.hostname,
            username: req.username,
            publicKey: req.publicKey,
            publicKeyFingerprint: req.publicKeyFingerprint,
            sshPort: req.sshPort
        )
        await transition(to: .completed(paired))
    }

    // MARK: - State transition helper

    private func transition(to newState: State) async {
        state = newState
        eventContinuation?.yield(.stateChanged(newState))
    }

    private func clearEventContinuation() {
        eventContinuation = nil
    }

    // MARK: - Local key material caching

    private func ensureLocalKeyMaterial() async throws {
        if localPubkeyBytes != nil { return }
        try await sshKeys.ensureKeyPair()
        do {
            self.localPubkeyLine = try await sshKeys.readPublicKey()
            self.localPubkeyBytes = try await sshKeys.readPublicKeyBytes()
            self.localPubkeyFingerprint = try await sshKeys.publicKeyFingerprint()
        } catch {
            throw PairingError.keyManagementFailed(String(describing: error))
        }
    }

    /// Read this Mac's SSH host key (preferring ed25519, falling back to
    /// rsa) so we can ferry it to the peer in the PairAccept payload for
    /// SEC-005 known_hosts pre-population.
    static func readLocalSshHostKey() throws -> String {
        // /etc/ssh/ssh_host_ed25519_key.pub is world-readable on macOS.
        let candidates = [
            "/etc/ssh/ssh_host_ed25519_key.pub",
            "/etc/ssh/ssh_host_rsa_key.pub",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let s = try? String(contentsOfFile: path, encoding: .utf8) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    /// Parse the raw 32-byte Ed25519 public key out of an OpenSSH
    /// `ssh-ed25519 AAAA... comment` line. Mirrors
    /// ``SSHKeyManager/readPublicKeyBytes`` so we can compute pairing codes
    /// for the *peer's* key, which we never write to disk.
    static func parsePublicKeyBytes(from line: String) throws -> Data {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw SSHKeyManager.KeyError.fingerprintParseFailed("malformed public key line")
        }
        guard let blob = Data(base64Encoded: String(parts[1])) else {
            throw SSHKeyManager.KeyError.fingerprintParseFailed("base64 decode failed")
        }
        guard blob.count >= 4 else {
            throw SSHKeyManager.KeyError.fingerprintParseFailed("blob too short")
        }
        let algoLen = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        let afterAlgo = 4 + algoLen
        guard blob.count >= afterAlgo + 4 else {
            throw SSHKeyManager.KeyError.fingerprintParseFailed("truncated after algo")
        }
        let keyLen = Int(blob[afterAlgo    ]) << 24
                   | Int(blob[afterAlgo + 1]) << 16
                   | Int(blob[afterAlgo + 2]) << 8
                   | Int(blob[afterAlgo + 3])
        let keyOffset = afterAlgo + 4
        guard blob.count >= keyOffset + keyLen else {
            throw SSHKeyManager.KeyError.fingerprintParseFailed("truncated payload")
        }
        return blob.subdata(in: keyOffset ..< keyOffset + keyLen)
    }
}
