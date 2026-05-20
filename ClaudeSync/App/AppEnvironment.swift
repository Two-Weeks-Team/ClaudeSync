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
    /// v1.1 (SEC-002): owns the local TLS identity used for the Bonjour
    /// control channel.
    let tlsProvider: TLSCertificateProvider
    /// v1.2: shares pairing fingerprints across the user's Macs via
    /// iCloud Keychain so same-Apple-ID Macs auto-pair without the
    /// visual 6-digit code.
    let iCloudShare: ICloudPairingShare
    /// v1.2.1: file-based fallback when iCloud Keychain is unavailable
    /// (errSecMissingEntitlement on ad-hoc-signed apps, the common case).
    /// Uses ~/Library/Mobile Documents/com.apple.CloudDocs/ClaudeSync/peers/.
    let iCloudDriveShare: ICloudDrivePairingShare

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
    /// v1.1.1: surfaced from PeerDiscoveryActor when TLS factory fails
    /// (e.g. openssl missing). UI shows a warning banner so the user
    /// knows the control channel is plaintext-only.
    var tlsDegradedReason: String?

    /// Snapshot of current preferences kept on the main actor for SwiftUI
    /// binding. Always written through `applyPreferences(_:)` so the
    /// PreferencesStore + RsyncCommandBuilder + LaunchAtLogin stay in sync.
    var currentPreferences: Preferences = .default

    private var discoveryTask: Task<Void, Never>?
    private var activePairing: PairingManager?
    private var activePairingTask: Task<Void, Never>?
    private var activeChannel: PeerChannel?
    /// v1.2: when set, the in-flight pairing was initiated via iCloud
    /// Keychain auto-pair. The observation closure auto-clicks Accept
    /// and Confirm IF the peer's actual fingerprint matches this value
    /// (defense-in-depth — keychain match could in theory be stale).
    private var autoPairExpectedFingerprint: String?
    /// v1.2.11: machineId of the peer we are currently *initiating* to.
    /// Used by `acceptIncomingPairing` to resolve the cross-initiate race
    /// (both sides clicked Pair) deterministically without closing each
    /// other's outbound. See `acceptIncomingPairing` for the tiebreaker.
    private var activePairingTargetMachineId: UUID?

    /// v1.2.12: dev/CI smoke-test toggle (env var `CLAUDESYNC_TEST_AUTO_PAIR=1`).
    /// When on, the pairing observer auto-accepts every inbound pairRequest
    /// and auto-confirms every pairAccept WITHOUT comparing the visual
    /// 6-digit code. Pair with `claudesync://pair?id=<machineId>` to
    /// initiate. Never enable in production — bypasses the human
    /// confirmation step that protects against a rogue peer on the LAN.
    static let testAutoPairMode: Bool =
        ProcessInfo.processInfo.environment["CLAUDESYNC_TEST_AUTO_PAIR"] == "1"
    /// v1.2.2: a `ProcessInfo` activity assertion held for the lifetime of
    /// an active pairing. ClaudeSync is a menu-bar-only (`LSUIElement`)
    /// app, so once the popover closes it has no visible window and macOS
    /// App Nap will throttle its run loop / dispatch queues — which can
    /// silently stall the control-channel `NWConnection` mid-handshake.
    /// `beginActivity(.userInitiated)` keeps the process scheduled (and
    /// disables sudden termination) while a pairing is in flight; released
    /// the moment it completes or fails. (Apple Energy Efficiency Guide:
    /// wrap user-initiated async work in `beginActivity`/`endActivity`.)
    private var pairingActivityToken: NSObjectProtocol?
    /// v1.1 (RCA-M5/M6/M7): observes Wi-Fi flaps + sleep/wake and triggers
    /// discovery restart with a small backoff so we don't thrash sshd or
    /// mDNSResponder.
    private var resilienceMonitor: NetworkResilienceMonitor?
    private var lastDiscoveryRestart: Date = .distantPast
    private static let discoveryRestartCooldown: TimeInterval = 3

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
            userExtraExcludes: extras,
            knownHostsPath: AppEnvironment.knownHostsPathIfPopulated(homeDirectory: homeDirectory)
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
        // SAFETY-001: construct the TrashJanitor with the user-configured
        // retention window from preferences.json (default 30, clamped ≥1
        // in Preferences.init). Without this, the preference field is
        // dead config — the coordinator's default `TrashJanitor()` would
        // always hardcode 30 days regardless of what the user set.
        let janitor = TrashJanitor(retentionDays: initialPrefs.trashRetentionDays)
        self.coordinator = SyncCoordinator(
            watcher: watcher,
            syncActor: syncActor,
            batchAccumulator: batchAccumulator,
            batchStream: batchStream,
            conflictResolver: resolver,
            trashJanitor: janitor
        )
        self.sshKeys = SSHKeyManager(homeDirectoryURL: homeDirectory)
        let identity = PairingManager.LocalIdentity(
            machineId: AppEnvironment.persistentMachineId(),
            hostname: AppEnvironment.localBonjourHostname(),
            username: NSUserName(),
            sshPort: 22
        )
        let tlsProvider = TLSCertificateProvider(homeDirectory: homeDirectory,
                                                 logger: logger)
        self.tlsProvider = tlsProvider
        self.discovery = PeerDiscoveryActor(
            identity: identity,
            tlsOptionsFactory: { pin in
                try await tlsProvider.makeOptions(pinnedFingerprint: pin)
            }
        )
        self.preferences = PreferencesStore()
        self.launchAtLogin = LaunchAtLoginController(logger: logger)
        self.iCloudShare = ICloudPairingShare(logger: logger)
        self.iCloudDriveShare = ICloudDrivePairingShare(
            homeDirectory: homeDirectory, logger: logger
        )
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

        // v1.2.14: refresh the rsync-server wrapper script every boot.
        // Idempotent (overwrites only when the file differs from what we
        // ship), so app upgrades propagate even when the user is already
        // paired and never re-pairs. The v1.2.14 wrapper uses `eval` to
        // preserve backslash-escaped spaces in remote paths (e.g.
        // `~/Library/Application\ Support/Claude/`) which the previous
        // unquoted `exec $rest` mangled into two arguments.
        try? await sshKeys.installRsyncWrapperIfMissing()

        // v1.2: publish our own pairing record to iCloud Keychain so any
        // other Mac signed into the same Apple ID can find us. Failure
        // is non-fatal — graceful fallback to the v1.1 visual-code path.
        if currentPreferences.autoPairSameAppleID {
            await publishOwnICloudRecord()
        }
        // v1.3.2: ~/Documents/GitHub is intentionally NOT synced. git is the
        // source of truth for projects — both Macs clone/pull independently,
        // so rsync-mirroring the working trees is redundant, heavy (thousands
        // of files inflate every file-list build and compounded the
        // SYNC-DEADLOCK timeouts), and risks clobbering a live `.git` working
        // tree mid-operation. The `.projects` target spec is kept in
        // SyncTarget for callers/tests, just dropped from the active watch set.
        await coordinator.start(targets: Set(SyncTarget.active))

        // RCA-C3: re-wire the previously-paired peer (if any) so sync starts
        // working immediately after launch, before discovery even completes.
        if let paired = activePairedPeer {
            await wirePairedPeerEndpoint(paired)
            overallStatus = .connected
            logger.info("Restored paired peer \(paired.hostname) from preferences",
                        category: "pairing")
        }

        await startBonjour()

        // v1.1: arm the network/sleep-wake monitor so we self-heal on
        // Wi-Fi flap or after the laptop wakes from sleep.
        if resilienceMonitor == nil {
            resilienceMonitor = NetworkResilienceMonitor(logger: logger) { [weak self] event in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.handleResilienceEvent(event)
                }
            }
            resilienceMonitor?.start()
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
                    // v1.2: if iCloud Keychain has a matching record for
                    // this peer's machineId AND auto-pair is enabled
                    // AND we don't already have a paired peer, kick off
                    // an automatic pairing — visual code skipped.
                    await self.maybeAutoPair(with: info)
                case .peerDisappeared(let mid):
                    self.discoveredPeers.removeAll { $0.machineId == mid }
                case .incomingConnection(let channel, _):
                    // Responder side: the peer is initiating pairing with us.
                    await self.acceptIncomingPairing(channel: channel)
                case .browserStateChanged, .listenerStateChanged:
                    break
                case .listenerFailed(let reason):
                    self.logger.warning("listener failed: \(reason) — restarting",
                                        category: "discovery")
                    await self.restartDiscoveryWithCooldown()
                case .browserFailed(let reason):
                    self.logger.warning("browser failed: \(reason) — restarting",
                                        category: "discovery")
                    await self.restartDiscoveryWithCooldown()
                }
            }
        }
    }

    /// v1.2: write our own pairing record to iCloud Keychain (preferred)
    /// AND iCloud Drive (v1.2.1 fallback). At least one needs to work
    /// for auto-pair; if both fail, the visual-code flow still works.
    ///
    /// Why both: iCloud Keychain requires `keychain-access-groups`
    /// entitlement which ad-hoc-signed builds don't have
    /// (errSecMissingEntitlement). iCloud Drive needs only file system
    /// access — works without Apple Developer Program. Belt and braces.
    private func publishOwnICloudRecord() async {
        let myMachineId = AppEnvironment.persistentMachineId()
        do {
            try await sshKeys.ensureKeyPair()
            let fingerprint = try await sshKeys.publicKeyFingerprint()
            let hostKey = (try? PairingManager.readLocalSshHostKey()) ?? ""
            let record = ICloudPairingShare.PeerRecord(
                machineId: myMachineId,
                hostname: AppEnvironment.localBonjourHostname(),
                username: NSUserName(),
                sshPort: 22,
                publicKeyFingerprint: fingerprint,
                sshHostKey: hostKey
            )
            let keychainOK = iCloudShare.publish(record)
            let driveOK    = iCloudDriveShare.publish(record)
            if !keychainOK && !driveOK {
                logger.info("Neither iCloud Keychain nor iCloud Drive available — visual-code flow only",
                            category: "icloud-pair")
            } else if !keychainOK && driveOK {
                logger.info("iCloud Drive fallback active — auto-pair will use file-based sync",
                            category: "icloud-pair")
            }
        } catch {
            logger.info("Skipped iCloud publish: \(error)",
                        category: "icloud-pair")
        }
    }

    /// Combined lookup: Keychain first, then Drive. Returns the first
    /// match (Keychain takes priority since it's E2E-encrypted).
    private func iCloudLookup(machineId: UUID) -> ICloudPairingShare.PeerRecord? {
        if let r = iCloudShare.lookup(machineId: machineId) { return r }
        return iCloudDriveShare.lookup(machineId: machineId)
    }

    /// Combined enumerate: union of Keychain + Drive records, dedupe
    /// by machineId. Used by the responder side which doesn't yet know
    /// which machineId to look up.
    private func iCloudAllRecords() -> [ICloudPairingShare.PeerRecord] {
        var seen: Set<UUID> = []
        var out: [ICloudPairingShare.PeerRecord] = []
        for r in iCloudShare.allRecords() + iCloudDriveShare.allRecords() {
            if seen.insert(r.machineId).inserted { out.append(r) }
        }
        return out
    }

    /// v1.2: when a peer appears via Bonjour, check whether iCloud Keychain
    /// has a matching record. If yes — same Apple ID, peer's TLS/SSH
    /// fingerprint matches what's published, and the user hasn't disabled
    /// auto-pair — initiate pairing AND auto-confirm without showing the
    /// 6-digit code.
    private func maybeAutoPair(with info: PeerInfo) async {
        // Preconditions
        guard currentPreferences.autoPairSameAppleID else { return }
        guard activePairing == nil else { return }              // mid-handshake
        guard activePairedPeer == nil else { return }           // already paired
        guard let record = iCloudLookup(machineId: info.machineId) else {
            return  // peer not on the same Apple ID — fall through to manual flow
        }
        logger.info("iCloud Keychain match for \(info.hostname) — initiating auto-pair",
                    category: "icloud-pair")

        // Mark this session as auto so the PairingManager observation
        // closure auto-clicks both Accept and Confirm when the codes
        // arrive (we still verify the cross-fingerprint server-side).
        autoPairExpectedFingerprint = record.publicKeyFingerprint
        do {
            try await initiatePairing(with: info)
        } catch {
            autoPairExpectedFingerprint = nil
            logger.warning("Auto-pair initiate failed: \(error)",
                           category: "icloud-pair")
        }
    }

    private func startBonjour() async {
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
        // v1.1.1: surface TLS degradation (e.g. openssl missing) to the UI
        // once we've actually attempted a handshake.
        tlsDegradedReason = await discovery.tlsDegradedReason
    }

    /// v1.1 (RCA-M5/M6/M7): respond to network/sleep events. We *always*
    /// debounce restarts behind a short cooldown to avoid hammering
    /// mDNSResponder on a flapping network.
    private func handleResilienceEvent(_ event: NetworkResilienceMonitor.Event) async {
        switch event {
        case .networkLost, .systemWillSleep:
            // Fast path: stop browsing/listening so we don't sit in a
            // half-broken state while the OS is reconfiguring.
            await discovery.stopBrowsing()
            await discovery.stopAdvertising()
            discoveredPeers.removeAll()
            if overallStatus != .idle { overallStatus = .discovering }
        case .networkRecovered, .systemDidWake:
            await restartDiscoveryWithCooldown()
        }
    }

    private func restartDiscoveryWithCooldown() async {
        let now = Date()
        if now.timeIntervalSince(lastDiscoveryRestart) < Self.discoveryRestartCooldown {
            return
        }
        lastDiscoveryRestart = now
        logger.info("restarting Bonjour after network/wake event",
                    category: "resilience")
        await discovery.stopBrowsing()
        await discovery.stopAdvertising()
        // Small breath so mDNSResponder finishes processing the cancel
        // before we re-register.
        try? await Task.sleep(for: .milliseconds(500))
        await startBonjour()
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
        logger.info("initiating pairing with \(peer.hostname) (\(peer.machineId.uuidString.prefix(8)))",
                    category: "pairing")
        activePairingTargetMachineId = peer.machineId
        let channel = try await discovery.connect(to: peer)
        let manager = makePairingManager(channel: channel)
        await beginPairingObservation(manager: manager)
        try await manager.initiate()
    }

    /// v1.2.12: dev/CI URL-scheme trigger:
    ///   open "claudesync://pair?id=<peer-machineId-uuid>"
    /// Resolves the machineId against `discoveredPeers` and starts pairing.
    /// Combined with `CLAUDESYNC_TEST_AUTO_PAIR=1` on both Macs the
    /// handshake completes without any GUI click — for end-to-end smoke
    /// tests. No-op when the URL is malformed or the peer isn't visible.
    func handleTestPairURL(_ url: URL) async {
        guard url.scheme == "claudesync", url.host == "pair" else {
            logger.warning("ignoring URL with unexpected scheme/host: \(url)", category: "pairing")
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let idStr = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
              let machineId = UUID(uuidString: idStr) else {
            logger.warning("claudesync://pair URL missing or malformed id=<UUID>: \(url)",
                           category: "pairing")
            return
        }
        guard let peer = discoveredPeers.first(where: { $0.machineId == machineId }) else {
            logger.warning("claudesync://pair: peer \(idStr) not in discoveredPeers (have \(discoveredPeers.count))",
                           category: "pairing")
            return
        }
        do {
            try await initiatePairing(with: peer)
        } catch {
            logger.warning("claudesync://pair initiate threw: \(error)", category: "pairing")
        }
    }

    /// Responder entry point — an inbound NWConnection arrived from a peer.
    private func acceptIncomingPairing(channel: PeerChannel) async {
        if activePairing != nil {
            // v1.2.11: cross-initiate race — both sides clicked Pair within a
            // few hundred ms. Before, the second side's `acceptIncomingPairing`
            // unconditionally closed the inbound, which `connection.cancel()`
            // FIN-promoted to the *other* side — killing both outbounds.
            // Resolve deterministically by machineId: the side with the smaller
            // machineId keeps its outbound (acts as initiator), the side with
            // the larger machineId aborts its outbound and accepts the inbound
            // (acts as responder). Both sides apply the same comparison so
            // exactly one connection survives.
            let myId = AppEnvironment.persistentMachineId()
            if let targetId = activePairingTargetMachineId {
                if myId.uuidString < targetId.uuidString {
                    // We win as initiator — close the inbound.
                    logger.info("cross-initiate race: keeping our outbound to \(targetId.uuidString.prefix(8)) (myId<targetId); closing inbound",
                                category: "pairing")
                    await channel.close(reason: "cross-initiate race — outbound wins (myId<targetId)")
                    return
                } else {
                    // We lose as initiator — abort our outbound, accept the
                    // inbound as responder. tearDownActivePairing closes our
                    // outbound channel (which is the OTHER side's listener-
                    // accepted inbound — they'll close it too via this same
                    // tiebreaker on their end, so the double-close is OK).
                    logger.info("cross-initiate race: aborting our outbound to \(targetId.uuidString.prefix(8)) (myId>targetId); switching to responder on inbound",
                                category: "pairing")
                    await tearDownActivePairing()
                    // fall through to accept the inbound below
                }
            } else {
                // No target id (shouldn't happen — only if accepted from a
                // non-initiate path). Preserve the old behaviour: close.
                logger.info("inbound pairing connection refused — already mid-pairing (no target id); closing it",
                            category: "pairing")
                await channel.close(reason: "inbound rejected — already have an active pairing")
                return
            }
        }
        logger.info("inbound pairing connection accepted — waiting for pairRequest", category: "pairing")
        // v1.2: if auto-pair is enabled AND iCloud Keychain has any
        // record (we don't yet know WHICH peer is calling — pairRequest
        // hasn't arrived — so set a sentinel that the observation
        // closure will validate against the actual peer fingerprint
        // once it arrives).
        if currentPreferences.autoPairSameAppleID {
            // Pick the first record whose machineId isn't ours; if
            // there are multiple iCloud peers this is best-effort.
            let myId = AppEnvironment.persistentMachineId()
            if let candidate = iCloudAllRecords()
                .first(where: { $0.machineId != myId }) {
                autoPairExpectedFingerprint = candidate.publicKeyFingerprint
                logger.info("Inbound pair while iCloud record present — auto-pair armed",
                            category: "icloud-pair")
            }
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
        // v1.2 / v1.2.1: remove our own record from BOTH share channels
        // so a previously-paired Mac doesn't keep auto-pairing back to us.
        let myId = AppEnvironment.persistentMachineId()
        iCloudShare.unpublish(machineId: myId)
        iCloudDriveShare.unpublish(machineId: myId)
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
        beginPairingActivity()
        return manager
    }

    /// v1.2.2: pin the process active for the duration of a pairing so App
    /// Nap can't throttle the menu-bar app while the control channel is
    /// mid-handshake. Idempotent.
    private func beginPairingActivity() {
        guard pairingActivityToken == nil else { return }
        pairingActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "ClaudeSync pairing handshake in progress"
        )
    }

    private func endPairingActivity() {
        if let token = pairingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            pairingActivityToken = nil
        }
    }

    private func beginPairingObservation(manager: PairingManager) async {
        let stream = await manager.events()
        activePairingTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                if case .stateChanged(let newState) = event {
                    self.activePairingState = newState
                    self.onboardingViewModel.updatePairingState(newState)

                    // v1.2: iCloud-Keychain auto-pair fast path —
                    // auto-click Accept (responder) and Confirm
                    // (initiator) when the peer's fingerprint matches
                    // what was published to iCloud Keychain.
                    //
                    // v1.2.12: ALSO auto-accept/confirm when launched with
                    // `CLAUDESYNC_TEST_AUTO_PAIR=1` (dev/CI smoke test —
                    // bypasses the visual code; never enable in production).
                    let expectedFP = self.autoPairExpectedFingerprint
                    switch newState {
                    case .receivedPairRequest(let req, _):
                        if AppEnvironment.testAutoPairMode {
                            self.logger.info("Auto-Accept (CLAUDESYNC_TEST_AUTO_PAIR=1)",
                                             category: "pairing")
                            await self.acceptPendingPairing()
                        } else if let fp = expectedFP, req.publicKeyFingerprint == fp {
                            self.logger.info("Auto-Accept (iCloud match)",
                                             category: "icloud-pair")
                            await self.acceptPendingPairing()
                        }
                    case .receivedPairAccept(let accept, _):
                        if AppEnvironment.testAutoPairMode {
                            self.logger.info("Auto-Confirm (CLAUDESYNC_TEST_AUTO_PAIR=1)",
                                             category: "pairing")
                            await self.confirmPairingCode()
                        } else if let fp = expectedFP, accept.publicKeyFingerprint == fp {
                            self.logger.info("Auto-Confirm (iCloud match)",
                                             category: "icloud-pair")
                            await self.confirmPairingCode()
                        }
                    default: break
                    }

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

        // v1.1 (SEC-005): if the peer shipped its SSH host key in
        // PairAcceptPayload, register it in our private known_hosts so
        // rsync's ssh transport stops relying on `accept-new` TOFU.
        if !paired.sshHostPublicKey.isEmpty {
            do {
                try await sshKeys.registerKnownHost(
                    hostname: paired.hostname,
                    hostKey: paired.sshHostPublicKey
                )
                logger.info("Registered known_hosts entry for \(paired.hostname)",
                            category: "pairing")
            } catch {
                logger.warning("known_hosts registration failed: \(error)",
                               category: "pairing")
            }
        }

        activePairedPeer = paired
        await wirePairedPeerEndpoint(paired)
        // v1.1 (SEC-005): rebuild the rsync command builder so the next
        // sync uses the freshly-populated known_hosts under strict mode.
        let extras = AppEnvironment.userExcludesByTarget(currentPreferences)
        let refreshed = RsyncCommandBuilder(
            bandwidthLimitKBps: currentPreferences.bandwidthLimitKBps,
            userExtraExcludes: extras,
            knownHostsPath: AppEnvironment.knownHostsPathIfPopulated(
                homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
            )
        )
        await syncActor.setBuilder(refreshed)
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
        endPairingActivity()
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
        logger.info("tearing down active pairing", category: "pairing")
        activePairingTask?.cancel()
        activePairingTask = nil
        if let ch = activeChannel { await ch.close(reason: "tearDownActivePairing") }
        activeChannel = nil
        activePairing = nil
        activePairingTargetMachineId = nil
        endPairingActivity()
        // v1.2: clear the auto-pair sentinel so the next handshake
        // starts cleanly.
        autoPairExpectedFingerprint = nil
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
            userExtraExcludes: extras,
            knownHostsPath: AppEnvironment.knownHostsPathIfPopulated(
                homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
            )
        )
        await syncActor.setBuilder(newBuilder)
        if launchAtLogin.isEnabled != next.launchAtLogin {
            _ = launchAtLogin.setEnabled(next.launchAtLogin)
        }
        currentPreferences = next
    }

    /// Returns the path to ~/.claudesync/ssh/known_hosts if it exists with
    /// at least one entry, otherwise empty string. Empty triggers the
    /// `accept-new` TOFU fallback (needed for the very first pairing
    /// before known_hosts has been populated).
    nonisolated private static func knownHostsPathIfPopulated(homeDirectory: URL) -> String {
        let url = homeDirectory.appendingPathComponent(".claudesync/ssh/known_hosts")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 0
        else { return "" }
        return url.path
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
        resilienceMonitor?.stop()
        resilienceMonitor = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        await discovery.stopBrowsing()
        await discovery.stopAdvertising()
        await coordinator.stop()
        isAutoStarted = false
        overallStatus = .idle
        discoveredPeers.removeAll()
        // v1.1: clean shutdown releases the single-instance sentinel so a
        // subsequent launch within the same second isn't tripped by a
        // stale PID.
        SingleInstanceGuard.releaseSentinel()
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
