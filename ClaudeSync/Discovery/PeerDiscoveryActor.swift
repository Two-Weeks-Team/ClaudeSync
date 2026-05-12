import Foundation
import Network

/// Owns the Bonjour `_claudesync._tcp` service registration *and* browsing.
/// Emits typed events via an `AsyncStream` so `SyncCoordinator` /
/// `PairingManager` can react without touching Network.framework.
///
/// The actor is intentionally small for Phase 2+3: it supports starting
/// advertising, starting browsing, connecting to a discovered peer (returning
/// a `PeerChannel` for handshake), and accepting inbound connections.
/// Heartbeat / sync notification flows live in the `PeerChannel` users.
public actor PeerDiscoveryActor {

    public enum PeerEvent: Sendable {
        case peerAppeared(PeerInfo)
        case peerDisappeared(machineId: UUID)
        case incomingConnection(PeerChannel, peerEndpointDescription: String)
        case browserStateChanged(String)
        case listenerStateChanged(String)
        /// v1.1 (RCA-M5): explicit listener-failed event so the owner can
        /// trigger a clean restart instead of relying on string-matching
        /// the generic `listenerStateChanged` payload.
        case listenerFailed(reason: String)
        case browserFailed(reason: String)
    }

    public static let serviceType = "_claudesync._tcp"
    public static let serviceDomain = "local."

    /// v1.2.4: ClaudeSync pairs two Macs **on the same Wi-Fi / LAN**, so we
    /// only need infrastructure-network Bonjour. Setting `includePeerToPeer`
    /// = true additionally opts into peer-to-peer Wi-Fi (AWDL), which Apple
    /// warns "can impact network performance" — in practice AWDL links are
    /// flaky: the radio periodically changes channels for AWDL polling, and
    /// an established connection that happened to be routed over AWDL can be
    /// dropped within seconds. Keeping this `false` forces the stable
    /// infrastructure path. (If a future use case needs cross-network
    /// discovery, flip this back on for the listener+browser only.)
    static let usePeerToPeerWiFi = false

    private let identity: PairingManager.LocalIdentity
    private let publicKeyFingerprint: String?
    private let logger = AppLogger.shared
    /// v1.1 (SEC-002): TLS options factory. When non-nil every NWListener
    /// and NWConnection layer-on a TLS protocol with our self-signed cert.
    /// When nil, the channel falls back to v1.0.x plaintext mode (used by
    /// the existing Loopback-only tests).
    private let tlsOptionsFactory: (@Sendable (String?) async throws -> NWProtocolTLS.Options)?
    /// v1.1.1 (cross-Mac robustness): when TLS factory throws once, we
    /// fall back to plaintext for the rest of the session and surface
    /// a single warning instead of failing every connection attempt.
    private var tlsDisabledReason: String?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpointsByMachineId: [UUID: NWEndpoint] = [:]
    private var eventContinuation: AsyncStream<PeerEvent>.Continuation?

    public init(identity: PairingManager.LocalIdentity,
                publicKeyFingerprint: String? = nil,
                tlsOptionsFactory: (@Sendable (String?) async throws -> NWProtocolTLS.Options)? = nil) {
        self.identity = identity
        self.publicKeyFingerprint = publicKeyFingerprint
        self.tlsOptionsFactory = tlsOptionsFactory
    }

    /// True if TLS is disabled this session (e.g. openssl missing on a
    /// freshly-cloned Mac without Homebrew).
    public var isTLSDegraded: Bool { tlsDisabledReason != nil }
    public var tlsDegradedReason: String? { tlsDisabledReason }

    /// Common path for both startAdvertising and connect: try TLS, on
    /// throw degrade to plaintext for the rest of the session.
    private func tlsOptionsOrFallback(pinnedFingerprint: String?) async -> NWProtocolTLS.Options? {
        guard let factory = tlsOptionsFactory else { return nil }
        if tlsDisabledReason != nil { return nil }
        do {
            return try await factory(pinnedFingerprint)
        } catch {
            let reason = String(describing: error)
            tlsDisabledReason = reason
            logger.warning(
                "TLS unavailable (\(reason)) — falling back to plaintext for the Bonjour control channel. The visual code + nonce + known_hosts layers still authenticate the peer.",
                category: "discovery"
            )
            return nil
        }
    }

    public func events() -> AsyncStream<PeerEvent> {
        AsyncStream<PeerEvent> { continuation in
            self.eventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearEventContinuation() }
            }
        }
    }

    private func clearEventContinuation() {
        eventContinuation = nil
    }

    // MARK: - Listener (advertise self)

    public func startAdvertising(paired: Bool = false) async throws {
        guard listener == nil else { throw PeerDiscoveryError.alreadyRunning }

        let tcpOptions = Self.tunedTCPOptions()

        // v1.1 (SEC-002): if a TLS factory is configured, layer TLS over
        // the TCP transport. Listener side uses no pin (responder accepts
        // any incoming cert and surfaces it post-handshake for pinning).
        // v1.1.1: if the factory throws (e.g. openssl missing on a freshly
        // cloned Mac), degrade to plaintext rather than failing the whole
        // discovery setup.
        let tlsOptions = await tlsOptionsOrFallback(pinnedFingerprint: nil)
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = Self.usePeerToPeerWiFi

        let framerOptions = NWProtocolFramer.Options(
            definition: ClaudeSyncProtocolFramer.definition
        )
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw PeerDiscoveryError.listenerSetupFailed(error.localizedDescription)
        }

        var txt = NWTXTRecord()
        txt[BonjourKeys.version]     = "1"
        txt[BonjourKeys.machineId]   = identity.machineId.uuidString
        txt[BonjourKeys.hostname]    = identity.hostname
        txt[BonjourKeys.username]    = identity.username
        txt[BonjourKeys.sshPort]     = String(identity.sshPort)
        txt[BonjourKeys.paired]      = paired ? "1" : "0"
        if let fp = publicKeyFingerprint {
            txt[BonjourKeys.publicKeyFP] = fp
        }

        listener.service = NWListener.Service(
            name: identity.machineId.uuidString,
            type: Self.serviceType,
            domain: Self.serviceDomain,
            txtRecord: txt
        )

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.emit(.listenerStateChanged(String(describing: state))) }
            if case .failed(let err) = state {
                Task { await self.emit(.listenerFailed(reason: err.localizedDescription)) }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleIncoming(connection: connection) }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Browser (find peers)

    public func startBrowsing() throws {
        guard browser == nil else { throw PeerDiscoveryError.alreadyRunning }

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Self.serviceType, domain: Self.serviceDomain
        )
        let parameters = NWParameters()
        parameters.includePeerToPeer = Self.usePeerToPeerWiFi

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.emit(.browserStateChanged(String(describing: state))) }
            if case .failed(let err) = state {
                Task { await self.emit(.browserFailed(reason: err.localizedDescription)) }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { await self.handleBrowseChanges(results: results, changes: changes) }
        }

        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        endpointsByMachineId.removeAll()
    }

    // MARK: - Connect

    /// Open a NWConnection-backed channel to a previously-discovered peer.
    /// `pinnedFingerprint` (hex SHA-256 of peer's TLS cert) defaults to nil
    /// for first-pairing TOFU; pass the cached value for paired-peer
    /// reconnects to enforce the pin.
    public func connect(to peer: PeerInfo,
                        pinnedFingerprint: String? = nil) async throws -> PeerChannel {
        guard let endpoint = endpointsByMachineId[peer.machineId] else {
            throw PeerDiscoveryError.noEndpointForPeer(peer.machineId)
        }
        let tlsOptions = await tlsOptionsOrFallback(pinnedFingerprint: pinnedFingerprint)
        // v1.2.2: the outbound side used default TCP options — no keepalive
        // — so a quiet established connection (e.g. waiting on the user to
        // confirm the 6-digit code) could be reaped by a NAT/router idle
        // timeout. Match the listener's tuned options on both ends.
        let parameters = NWParameters(tls: tlsOptions, tcp: Self.tunedTCPOptions())
        parameters.includePeerToPeer = Self.usePeerToPeerWiFi
        let framerOptions = NWProtocolFramer.Options(
            definition: ClaudeSyncProtocolFramer.definition
        )
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let conn = NWConnection(to: endpoint, using: parameters)
        return NWConnectionPeerChannel(connection: conn)
    }

    /// Shared TCP options for both the listener and outbound connections:
    /// a 10 s connect timeout plus aggressive keepalive so a half-open or
    /// idle connection is detected (and refreshed) within ~25 s rather
    /// than the kernel default of several minutes.
    static func tunedTCPOptions() -> NWProtocolTCP.Options {
        let opts = NWProtocolTCP.Options()
        opts.connectionTimeout = 10
        opts.enableKeepalive = true
        opts.keepaliveIdle = 10
        opts.keepaliveInterval = 5
        opts.keepaliveCount = 3
        return opts
    }

    // MARK: - Internals

    private func emit(_ event: PeerEvent) {
        eventContinuation?.yield(event)
    }

    private func handleIncoming(connection: NWConnection) async {
        let channel = NWConnectionPeerChannel(connection: connection)
        emit(.incomingConnection(channel, peerEndpointDescription: String(describing: connection.endpoint)))
    }

    private func handleBrowseChanges(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) async {
        for change in changes {
            switch change {
            case .added(let result):
                if let info = decode(result: result) {
                    endpointsByMachineId[info.machineId] = result.endpoint
                    emit(.peerAppeared(info))
                }
            case .removed(let result):
                if let info = decode(result: result) {
                    endpointsByMachineId.removeValue(forKey: info.machineId)
                    emit(.peerDisappeared(machineId: info.machineId))
                }
            case .changed(_, let new, _):
                if let info = decode(result: new) {
                    endpointsByMachineId[info.machineId] = new.endpoint
                    emit(.peerAppeared(info))
                }
            case .identical:
                break
            @unknown default:
                break
            }
        }
        // Sanity: cull any endpoints no longer in `results`.
        let currentIds: Set<UUID> = Set(results.compactMap { decode(result: $0)?.machineId })
        for staleId in endpointsByMachineId.keys where !currentIds.contains(staleId) {
            endpointsByMachineId.removeValue(forKey: staleId)
            emit(.peerDisappeared(machineId: staleId))
        }
    }

    private func decode(result: NWBrowser.Result) -> PeerInfo? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        let info = PeerInfo.decode(
            txt: txt,
            endpointDescription: String(describing: result.endpoint)
        )
        // Filter out self by machineId.
        if let info, info.machineId == identity.machineId { return nil }
        return info
    }
}
