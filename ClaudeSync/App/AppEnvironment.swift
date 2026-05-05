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
    /// necessarily paired). Phase 6.5 placeholder — full pairing flow will
    /// drive this once it lands.
    var discoveredPeers: [PeerInfo] = []

    private var discoveryTask: Task<Void, Never>?

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
                case .incomingConnection, .browserStateChanged, .listenerStateChanged:
                    break
                }
            }
        }
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
