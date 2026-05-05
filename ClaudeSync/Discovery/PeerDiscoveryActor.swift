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

    private let identity: PairingManager.LocalIdentity
    private let publicKeyFingerprint: String?
    private let logger = AppLogger.shared
    /// v1.1 (SEC-002): TLS options factory. When non-nil every NWListener
    /// and NWConnection layer-on a TLS protocol with our self-signed cert.
    /// When nil, the channel falls back to v1.0.x plaintext mode (used by
    /// the existing Loopback-only tests).
    private let tlsOptionsFactory: (@Sendable (String?) async throws -> NWProtocolTLS.Options)?

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

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10
        tcpOptions.enableKeepalive = true

        // v1.1 (SEC-002): if a TLS factory is configured, layer TLS over
        // the TCP transport. Listener side uses no pin (responder accepts
        // any incoming cert and surfaces it post-handshake for pinning).
        let tlsOptions: NWProtocolTLS.Options?
        if let factory = tlsOptionsFactory {
            tlsOptions = try await factory(nil)
        } else {
            tlsOptions = nil
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = true

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
        parameters.includePeerToPeer = true

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
        let tlsOptions: NWProtocolTLS.Options?
        if let factory = tlsOptionsFactory {
            tlsOptions = try await factory(pinnedFingerprint)
        } else {
            tlsOptions = nil
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        let framerOptions = NWProtocolFramer.Options(
            definition: ClaudeSyncProtocolFramer.definition
        )
        parameters.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let conn = NWConnection(to: endpoint, using: parameters)
        return NWConnectionPeerChannel(connection: conn)
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
