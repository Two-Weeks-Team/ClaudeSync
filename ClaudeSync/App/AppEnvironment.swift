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
    let preferences: PreferencesStore
    let launchAtLogin: LaunchAtLoginController

    /// Onboarding state machine — bound to the FirstLaunchPairingView.
    /// v1.0.1 (RCA-C1): closures wired so the view's Accept/Confirm/Reject
    /// buttons actually call into PairingManager. Before v1.0.1 this model
    /// existed but was created fresh inside the view, leaving callbacks nil.
    let onboardingViewModel: OnboardingViewModel

    // MARK: - Published UI state

    var overallStatus: OverallStatus = .idle
    var needsOnboarding: Bool = true
    var isAutoStarted: Bool = false
    /// Peers currently visible on the local network (Bonjour-discovered, not
    /// necessarily paired).
    var discoveredPeers: [PeerInfo] = []

    /// Currently in-flight pairing, if any. Surface this to the UI so the
    /// onboarding window AND the menu bar popover can prompt the user.
    var activePairingState: PairingManager.State = .idle
    /// In-memory copy of the most recently paired peer. Persisted through
    /// `preferences.pairedPeer` so the wiring survives app restarts (RCA-C3).
    var activePairedPeer: PairingManager.PairedPeer?

    /// Snapshot of current preferences kept on the main actor for SwiftUI
    /// binding. Always written through `applyPreferences(_:)` so the
    /// PreferencesStore + RsyncCommandBuilder + LaunchAtLogin stay in sync.
    var currentPreferences: Preferences = .default

    private var discoveryTask: Task<Void, Never>?
    private var activePairing: PairingManager?
    private var activePairingTask: Task<Void, Never>?
    private var activeChannel: PeerChannel?

    init(
        logger: AppLogger = .shared,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.logger = logger
        let initialPrefs = Preferences.loadInitialSync(from: PreferencesStore.defaultURL)
        let watcherCfg = FileWatcherActor.Configuration(homeDirectory: homeDirectory)
        let watcher = FileWatcherActor(config: watcherCfg)
        let extras = AppEnvironment.userExcludesByTarget(initialPrefs)
        let builder = RsyncCommandBuilder(
            bandwidthLimitKBps: initialPrefs.bandwidthLimitKBps,
            userExtraExcludes: extras
        )
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
            hostname: AppEnvironment.localBonjourHostname(),
            username: NSUserName(),
            sshPort: 22
        )
        self.discovery = PeerDiscoveryActor(identity: identity)
        self.preferences = PreferencesStore()
        self.launchAtLogin = LaunchAtLoginController(logger: logger)
        self.currentPreferences = initialPrefs
        self.onboardingViewModel = OnboardingViewModel()
        self.activePairedPeer = AppEnvironment.restorePairedPeer(from: initialPrefs)
        self.needsOnboarding = (initialPrefs.pairedPeer == nil)

        logger.info("AppEnvironment initialized — onboarding=\(needsOnboarding)",
                    category: "app")

        // Wire the onboarding view's Accept/Confirm/Reject buttons to our
        // pairing actions. (RCA-C1: before v1.0.1 these closures were nil
        // and the buttons silently no-op'd.)
        wireOnboardingCallbacks()

        // Auto-boot the sync engine + Bonjour discovery on app launch so the
        // user doesn't have to click the menu bar to get things going.
        Task { @MainActor [weak self] in
            await self?.bootSyncEngine()
        }
    }

    // MARK: - Stable identity helpers

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

    /// Returns a Bonjour/SSH-safe hostname. v1.0.1 (CR-C4 / SEC-006):
    /// `Host.current().localizedName` returns user-set names like
    /// "Kim's MacBook Air" with spaces and apostrophes — those break SSH
    /// command-line construction and Bonjour TXT records. Prefer the system
    /// `.local` name (set by macOS, contains only DNS-safe characters).
    private static func localBonjourHostname() -> String {
        // 1) Prefer Host.current().names that end in .local — these are DNS-safe.
        if let dnsName = Host.current().names.first(where: { $0.hasSuffix(".local") }) {
            return String(dnsName.dropLast(".local".count))
        }
        // 2) Fall back to ProcessInfo.hostName (typically "<computer-name>.local").
        let raw = ProcessInfo.processInfo.hostName
        let trimmed = raw.hasSuffix(".local")
            ? String(raw.dropLast(".local".count))
            : raw
        // 3) Final safety net: strip any character outside [a-zA-Z0-9._-].
        return trimmed.filter {
            $0.isASCII && (
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            )
        }
    }

    /// Predicate used to validate hostnames/usernames received from peers.
    /// Defends against shell-meta injection in rsync command construction.
    nonisolated static func isSafeNetworkIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        for ch in s {
            let ok = ch.isASCII && (
                ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
            )
            if !ok { return false }
        }
        return true
    }

    private static func restorePairedPeer(from prefs: Preferences) -> PairingManager.PairedPeer? {
        guard let rec = prefs.pairedPeer else { return nil }
        // Note: publicKey is stored in authorized_keys on disk; we don't keep
        // the raw key blob in Preferences. The UI only needs identifying
        // metadata (machineId/hostname/username/sshPort/fingerprint) to show
        // "paired with" status — actual SSH auth uses the on-disk key.
        return PairingManager.PairedPeer(
            machineId: rec.machineId,
            hostname: rec.hostname,
            username: rec.username,
            publicKey: "",
            publicKeyFingerprint: rec.publicKeyFingerprint,
            sshPort: rec.sshPort
        )
    }

    /// Boot the watcher + coordinator + discovery. Safe to call multiple
    /// times — internal guards prevent double-start.
    func bootSyncEngine() async {
        guard !isAutoStarted else { return }
        isAutoStarted = true
        logger.info("Booting sync engine + discovery", category: "app")
        // RCA-M1: include .projects in the watch set so on-demand pulls work
        // when the user clicks "Force Sync" on Documents/GitHub. Without
        // this the watcher never spins up the project FSEvent stream.
        await coordinator.start(targets: [
            .claudeConfig, .claudeAppSupport, .codexConfig, .projects
        ])

        // RCA-C3: re-wire the previously-paired peer (if any) so sync starts
        // working immediately after launch, before discovery even completes.
        if let paired = activePairedPeer {
            await wirePairedPeerEndpoint(paired)
            overallStatus = .connected
            logger.info("Restored paired peer \(paired.hostname) from preferences",
                        category: "pairing")
        }

        do {
            try await discovery.startAdvertising()
            logger.info("Bonjour advertising started", category: "discovery")
            try await discovery.startBrowsing()
            logger.info("Bonjour browsing started", category: "discovery")
            if overallStatus == .idle { overallStatus = .discovering }
        } catch {
            logger.warning("discovery setup failed: \(error)", category: "discovery")
            if overallStatus == .idle { overallStatus = .error("discovery failed") }
        }

        // Pump discovery events into our published peer list. We never
        // auto-pair — the user must explicitly accept via the onboarding
        // window or the menu bar popover.
        let stream = await discovery.events()
        discoveryTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                switch event {
                case .peerAppeared(let info):
                    if !self.discoveredPeers.contains(info) {
                        self.discoveredPeers.append(info)
                    }
                    // RCA-C1 wiring: nudge onboarding from "discovery" to
                    // "pairingCode" once any peer is visible.
                    self.onboardingViewModel.discoveryFoundPeer()
                case .peerDisappeared(let mid):
                    self.discoveredPeers.removeAll { $0.machineId == mid }
                case .incomingConnection(let channel, _):
                    // Responder side: the peer is initiating pairing with us.
                    await self.acceptIncomingPairing(channel: channel)
                case .browserStateChanged, .listenerStateChanged:
                    break
                }
            }
        }
    }

    // MARK: - Pairing

    /// Initiator entry point — user clicked "Pair with X" in the onboarding
    /// or menu bar UI.
    func initiatePairing(with peer: PeerInfo) async throws {
        guard activePairing == nil else { return }
        // SEC-006 / CR-C4: refuse to construct an SSH address from a peer
        // whose hostname contains shell metacharacters or whitespace.
        guard Self.isSafeNetworkIdentifier(peer.hostname),
              Self.isSafeNetworkIdentifier(peer.username) else {
            logger.warning("rejecting pair-initiate with unsafe identifiers (\(peer.hostname)/\(peer.username))",
                           category: "pairing")
            throw PairingManager.PairingError.invalidStateForAction(
                currentState: "rejected", action: "initiate"
            )
        }
        let channel = try await discovery.connect(to: peer)
        let manager = makePairingManager(channel: channel)
        await beginPairingObservation(manager: manager)
        try await manager.initiate()
    }

    /// Responder entry point — an inbound NWConnection arrived from a peer.
    private func acceptIncomingPairing(channel: PeerChannel) async {
        guard activePairing == nil else {
            // We're already mid-pairing; refuse this one cleanly.
            await channel.close()
            return
        }
        let manager = makePairingManager(channel: channel)
        await beginPairingObservation(manager: manager)
        // Start listening so incoming pairRequest is processed.
        try? await manager.start()
        // Surface incoming-pairing in the menu bar even if onboarding window
        // isn't open — the popover shows a code+confirm banner.
        onboardingViewModel.discoveryFoundPeer()
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

    /// User wants to forget the current paired peer (Settings → Forget).
    func forgetPairedPeer() async {
        activePairedPeer = nil
        await syncActor.setPeer(nil)
        await applyPreferences({
            var p = self.currentPreferences
            p.pairedPeer = nil
            return p
        }())
        overallStatus = isAutoStarted ? .discovering : .idle
        needsOnboarding = true
    }

    private func makePairingManager(channel: PeerChannel) -> PairingManager {
        let identity = PairingManager.LocalIdentity(
            machineId: AppEnvironment.persistentMachineId(),
            hostname: AppEnvironment.localBonjourHostname(),
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
                    self.onboardingViewModel.updatePairingState(newState)
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
        // SEC-006 defense-in-depth: even on the receiving end of a pairing,
        // refuse to wire an unsafe peer into the rsync command line.
        guard Self.isSafeNetworkIdentifier(paired.hostname),
              Self.isSafeNetworkIdentifier(paired.username) else {
            logger.warning("rejecting completed pairing with unsafe identifiers",
                           category: "pairing")
            await tearDownActivePairing()
            return
        }

        activePairedPeer = paired
        await wirePairedPeerEndpoint(paired)
        // RCA-C3: persist so the next launch reuses this peer without prompting.
        let record = PairedPeerRecord(
            machineId: paired.machineId,
            hostname: paired.hostname,
            username: paired.username,
            publicKeyFingerprint: paired.publicKeyFingerprint,
            sshPort: paired.sshPort
        )
        await applyPreferences({
            var p = self.currentPreferences
            p.pairedPeer = record
            return p
        }())
        overallStatus = .connected
        needsOnboarding = false
        logger.info("Paired with \(paired.hostname) — sync engine peer wired",
                    category: "pairing")
    }

    /// Construct and inject the SSH endpoint into the FileSyncActor.
    private func wirePairedPeerEndpoint(_ paired: PairingManager.PairedPeer) async {
        let endpoint = RsyncCommandBuilder.PeerEndpoint(
            sshAddress: "\(paired.username)@\(paired.hostname).local",
            sshPort: paired.sshPort
        )
        await syncActor.setPeer(endpoint)
    }

    private func tearDownActivePairing() async {
        activePairingTask?.cancel()
        activePairingTask = nil
        if let ch = activeChannel { await ch.close() }
        activeChannel = nil
        activePairing = nil
    }

    private func wireOnboardingCallbacks() {
        onboardingViewModel.onAcceptPair = { [weak self] in
            await self?.acceptPendingPairing()
        }
        onboardingViewModel.onConfirmPair = { [weak self] in
            await self?.confirmPairingCode()
        }
        onboardingViewModel.onRejectPair = { [weak self] reason in
            await self?.rejectActivePairing(reason: reason)
        }
    }

    // MARK: - Preferences

    /// Apply a new preferences snapshot: persist it, push the bandwidth/exclude
    /// changes into the FileSyncActor, and reconcile the Launch-at-Login state
    /// with macOS ServiceManagement. Failures are logged, never thrown — UI
    /// surfaces the post-apply state via `currentPreferences`.
    func applyPreferences(_ next: Preferences) async {
        do {
            try await preferences.replace(next)
        } catch {
            logger.warning("Preferences persist failed: \(error)",
                           category: "preferences")
        }
        let extras = AppEnvironment.userExcludesByTarget(next)
        let newBuilder = RsyncCommandBuilder(
            bandwidthLimitKBps: next.bandwidthLimitKBps,
            userExtraExcludes: extras
        )
        await syncActor.setBuilder(newBuilder)
        if launchAtLogin.isEnabled != next.launchAtLogin {
            _ = launchAtLogin.setEnabled(next.launchAtLogin)
        }
        currentPreferences = next
    }

    private static func userExcludesByTarget(_ prefs: Preferences) -> [SyncTarget: [String]] {
        var dict: [SyncTarget: [String]] = [:]
        for target in SyncTarget.allCases {
            let extras = prefs.extraExcludes(for: target)
            if !extras.isEmpty { dict[target] = extras }
        }
        return dict
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
