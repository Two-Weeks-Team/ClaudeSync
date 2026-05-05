import Foundation
import SwiftUI

/// Top-level dependency container for the SwiftUI scene tree. Owns the
/// long-lived actors (FileWatcherActor, FileSyncActor, BatchAccumulator,
/// SyncCoordinator) and exposes their state as published `@Observable`
/// properties for the menu bar UI.
@MainActor
@Observable
final class AppEnvironment {
    let logger: AppLogger

    // MARK: - Long-lived domain actors

    let watcher: FileWatcherActor
    let syncActor: FileSyncActor
    let batchAccumulator: BatchAccumulator
    let conflictResolver: ConflictResolver
    let coordinator: SyncCoordinator
    let sshKeys: SSHKeyManager
    let discovery: PeerDiscoveryActor

    // MARK: - Published UI state

    var overallStatus: OverallStatus = .idle
    var needsOnboarding: Bool = true
    var isAutoStarted: Bool = false
    /// Peers currently visible on the local network (Bonjour-discovered, not
    /// necessarily paired).
    var discoveredPeers: [PeerInfo] = []

    /// Currently in-flight pairing, if any. Surface this to the UI so the
    /// onboarding window can prompt the user.
    var activePairingState: PairingManager.State = .idle
    var activePairedPeer: PairingManager.PairedPeer?

    private var discoveryTask: Task<Void, Never>?
    private var activePairing: PairingManager?
    private var activePairingTask: Task<Void, Never>?
    private var activeChannel: NWConnectionPeerChannel?

    init(
        logger: AppLogger = .shared,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.logger = logger
        let watcherCfg = FileWatcherActor.Configuration(homeDirectory: homeDirectory)
        let watcher = FileWatcherActor(config: watcherCfg)
        let builder = RsyncCommandBuilder()
        let syncActor = FileSyncActor(
            config: .init(builder: builder),
            watcher: watcher,
            peer: nil
        )
        let (batchStream, batchAccumulator) = BatchAccumulator.makeStream(flushInterval: .seconds(300))
        let resolver = ConflictResolver()

        self.watcher = watcher
        self.syncActor = syncActor
        self.batchAccumulator = batchAccumulator
        self.conflictResolver = resolver
        self.coordinator = SyncCoordinator(
            watcher: watcher,
            syncActor: syncActor,
            batchAccumulator: batchAccumulator,
            batchStream: batchStream,
            conflictResolver: resolver
        )
        self.sshKeys = SSHKeyManager(homeDirectoryURL: homeDirectory)
        let identity = PairingManager.LocalIdentity(
            machineId: AppEnvironment.persistentMachineId(),
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            username: NSUserName(),
            sshPort: 22
        )
        self.discovery = PeerDiscoveryActor(identity: identity)

        logger.info("AppEnvironment initialized", category: "app")

        // Auto-boot the sync engine + Bonjour discovery on app launch so the
        // user doesn't have to click the menu bar to get things going.
        Task { @MainActor [weak self] in
            await self?.bootSyncEngine()
        }
    }

    /// Stable per-machine UUID, persisted in UserDefaults so the same Mac
    /// advertises the same id across launches. Required so the peer can tell
    /// us apart when we re-appear on Bonjour.
    private static func persistentMachineId() -> UUID {
        let key = "com.claudesync.machineId"
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    /// Boot the watcher + coordinator + discovery. Safe to call multiple
    /// times — internal guards prevent double-start.
    func bootSyncEngine() async {
        guard !isAutoStarted else { return }
        isAutoStarted = true
        logger.info("Booting sync engine + discovery", category: "app")
        await coordinator.start(targets: [.claudeConfig, .claudeAppSupport, .codexConfig])
        do {
            try await discovery.startAdvertising()
            logger.info("Bonjour advertising started", category: "discovery")
            try await discovery.startBrowsing()
            logger.info("Bonjour browsing started", category: "discovery")
            overallStatus = .discovering
        } catch {
            logger.warning("discovery setup failed: \(error)", category: "discovery")
            overallStatus = .connected
        }

        // Pump discovery events into our published peer list. We never
        // auto-pair — the user must explicitly accept via the onboarding
        // window. This pump just makes peers visible in the menu bar.
        let stream = await discovery.events()
        discoveryTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                switch event {
                case .peerAppeared(let info):
                    if !self.discoveredPeers.contains(info) {
                        self.discoveredPeers.append(info)
                    }
                case .peerDisappeared(let mid):
                    self.discoveredPeers.removeAll { $0.machineId == mid }
                case .incomingConnection(let channel, _):
                    // Responder side: the peer is initiating pairing with us.
                    await self.acceptIncomingPairing(channel: channel as! NWConnectionPeerChannel)
                case .browserStateChanged, .listenerStateChanged:
                    break
                }
            }
        }
    }

    // MARK: - Pairing

    /// Initiator entry point — user clicked "Pair with X" in the onboarding UI.
    func initiatePairing(with peer: PeerInfo) async throws {
        guard activePairing == nil else { return }
        let channel = try await discovery.connect(to: peer) as! NWConnectionPeerChannel
        let manager = makePairingManager(channel: channel)
        await beginPairingObservation(manager: manager)
        try await manager.initiate()
    }

    /// Responder entry point — an inbound NWConnection arrived from a peer.
    private func acceptIncomingPairing(channel: NWConnectionPeerChannel) async {
        guard activePairing == nil else {
            // We're already mid-pairing; refuse this one cleanly.
            await channel.close()
            return
        }
        let manager = makePairingManager(channel: channel)
        await beginPairingObservation(manager: manager)
        // Start listening so incoming pairRequest is processed.
        try? await manager.start()
    }

    /// User accepted the pending pairRequest in the UI.
    func acceptPendingPairing() async {
        guard let manager = activePairing else { return }
        try? await manager.acceptPendingRequest()
    }

    /// User confirmed the displayed code matches.
    func confirmPairingCode() async {
        guard let manager = activePairing else { return }
        try? await manager.confirmCode()
    }

    /// User rejected at any step.
    func rejectActivePairing(reason: String = "user-cancelled") async {
        guard let manager = activePairing else { return }
        try? await manager.reject(reason: reason)
    }

    private func makePairingManager(channel: NWConnectionPeerChannel) -> PairingManager {
        let identity = PairingManager.LocalIdentity(
            machineId: AppEnvironment.persistentMachineId(),
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            username: NSUserName(), sshPort: 22
        )
        let manager = PairingManager(channel: channel, sshKeys: sshKeys, identity: identity)
        activePairing = manager
        activeChannel = channel
        return manager
    }

    private func beginPairingObservation(manager: PairingManager) async {
        let stream = await manager.events()
        activePairingTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                if case .stateChanged(let newState) = event {
                    self.activePairingState = newState
                    if case .completed(let paired) = newState {
                        await self.handlePairingCompleted(paired)
                    }
                    if case .rejected = newState { await self.tearDownActivePairing() }
                    if case .failed = newState   { await self.tearDownActivePairing() }
                }
            }
        }
    }

    private func handlePairingCompleted(_ paired: PairingManager.PairedPeer) async {
        activePairedPeer = paired
        // Wire the just-paired peer into the FileSyncActor so future jobs
        // actually go over SSH instead of failing with "no peer configured".
        let endpoint = RsyncCommandBuilder.PeerEndpoint(
            sshAddress: "\(paired.username)@\(paired.hostname).local",
            sshPort: paired.sshPort
        )
        await syncActor.setPeer(endpoint)
        overallStatus = .connected
        logger.info("Paired with \(paired.hostname) — sync engine peer wired", category: "pairing")
    }

    private func tearDownActivePairing() async {
        activePairingTask?.cancel()
        activePairingTask = nil
        if let ch = activeChannel { await ch.close() }
        activeChannel = nil
        activePairing = nil
    }

    func shutdownSyncEngine() async {
        guard isAutoStarted else { return }
        discoveryTask?.cancel()
        discoveryTask = nil
        await discovery.stopBrowsing()
        await discovery.stopAdvertising()
        await coordinator.stop()
        isAutoStarted = false
        overallStatus = .idle
        discoveredPeers.removeAll()
    }

    enum OverallStatus: Equatable {
        case idle
        case discovering
        case connected
        case syncing
        case error(String)

        var systemImageName: String {
            switch self {
            case .idle:        return "circle.dashed"
            case .discovering: return "antenna.radiowaves.left.and.right"
            case .connected:   return "checkmark.circle"
            case .syncing:     return "arrow.triangle.2.circlepath"
            case .error:       return "exclamationmark.triangle"
            }
        }

        var shortLabel: String {
            switch self {
            case .idle:           return "Idle"
            case .discovering:    return "Searching for peer…"
            case .connected:      return "Watching"
            case .syncing:        return "Syncing…"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }
}
