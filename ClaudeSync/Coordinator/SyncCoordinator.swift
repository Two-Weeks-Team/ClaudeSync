import Foundation
import SwiftUI

/// Top-level orchestrator. Subscribes to FileWatcherActor's `(target, tier,
/// paths)` batches, routes Tier 2 batches into the BatchAccumulator, and hands
/// every emission to the FileSyncActor as a `SyncJob`.
///
/// Phase 5 wires the production pipeline up to (but not including) the
/// ConflictResolver loop — conflict detection runs lazily as part of rsync's
/// own `--update` semantics for now. A proper dry-run-then-resolve flow comes
/// in Phase 6 polish if needed.
@MainActor
@Observable
public final class SyncCoordinator {

    public enum CoordinatorState: Equatable, Sendable {
        case idle
        case watching
        case syncing(activeJobs: Int)
        case error(message: String)
    }

    public private(set) var state: CoordinatorState = .idle
    public private(set) var lastSyncTimes: [SyncTarget: Date] = [:]
    public private(set) var recentResults: [SyncResult.ResultStatus] = []

    public let watcher: FileWatcherActor
    public let syncActor: FileSyncActor
    public let batchAccumulator: BatchAccumulator
    public let batchStream: AsyncStream<BatchAccumulator.Output>
    public let conflictResolver: ConflictResolver
    /// SAFETY-001: owns the daily quarantine sweep. Started in `start()`,
    /// cancelled in `stop()`. Optional so unit tests that construct a
    /// minimal coordinator can pass nil and skip the side effect.
    public let trashJanitor: TrashJanitor?

    /// SYNC-RECONCILE: cadence of the automatic full-sync. Incremental
    /// (FSEvent-driven) syncs only ever carry the *changed* files —
    /// `--include <file> … --exclude *` — so a file that never changes
    /// (e.g. a skill or slash-command authored on the peer, or one that
    /// predates pairing) is NEVER reconciled by incremental traffic. The
    /// only path that transfers an unchanged-but-divergent file is a full
    /// sync (`isFullSync`, no `--exclude *`), which until now fired solely
    /// from the manual ⟳ button. This timer runs one full sync per watched
    /// target on a cadence so skills/commands/etc. converge without user
    /// action. `.zero` disables the timer (used by tests that assert
    /// nothing else).
    public let fullSyncInterval: Duration
    /// Grace period after `start()` before the first automatic full sync,
    /// so pairing-restore (which sets the peer) has settled — otherwise the
    /// job is dropped by `FileSyncActor.enqueue` (peer == nil). The loop
    /// also polls for peer readiness, so this is just the floor.
    public let initialFullSyncDelay: Duration

    private var watchedTargets: Set<SyncTarget> = []
    private var watcherTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var fullSyncTask: Task<Void, Never>?

    public init(
        watcher: FileWatcherActor,
        syncActor: FileSyncActor,
        batchAccumulator: BatchAccumulator,
        batchStream: AsyncStream<BatchAccumulator.Output>,
        conflictResolver: ConflictResolver = ConflictResolver(),
        trashJanitor: TrashJanitor? = TrashJanitor(),
        fullSyncInterval: Duration = .seconds(600),
        initialFullSyncDelay: Duration = .seconds(15)
    ) {
        self.watcher = watcher
        self.syncActor = syncActor
        self.batchAccumulator = batchAccumulator
        self.batchStream = batchStream
        self.conflictResolver = conflictResolver
        self.trashJanitor = trashJanitor
        self.fullSyncInterval = fullSyncInterval
        self.initialFullSyncDelay = initialFullSyncDelay
    }

    // MARK: - Lifecycle

    public func start(targets: Set<SyncTarget> = [.claudeConfig, .claudeAppSupport, .codexConfig]) async {
        watchedTargets = targets
        await watcher.startWatching(targets: targets)
        state = .watching

        // SAFETY-001: start the daily quarantine sweep. Detached so it
        // never blocks the watcher pumps below, and self-cancelling on
        // stop().
        if let janitor = trashJanitor {
            await janitor.start()
        }

        // SYNC-RECONCILE: kick the periodic full-sync loop so unchanged-but-
        // divergent files (skills, commands, …) converge without the user
        // pressing ⟳. No-op when the target set is empty (tests) or the
        // interval is `.zero`.
        startPeriodicFullSync()

        // Pump 1: file-watcher batches → either enqueue immediately (real-time)
        // or hand to the accumulator (batched). On-demand tier is dropped
        // here; a separate manual-trigger API will wake those.
        let watcherStream = watcher.changes()
        watcherTask = Task { [weak self] in
            for await batch in watcherStream {
                guard let self else { break }
                await self.routeWatcherBatch(batch)
            }
        }

        // Pump 2: accumulator flushes → enqueue as low-priority push.
        let batchPath = batchStream
        batchTask = Task { [weak self] in
            for await batch in batchPath {
                guard let self else { break }
                let job = SyncJob(
                    target: batch.target,
                    paths: batch.paths,
                    direction: .push,
                    priority: .low,
                    tier: .batched
                )
                await self.syncActor.enqueue(job)
            }
        }

        // Pump 3: sync results → update UI state.
        let results = syncActor.results()
        resultsTask = Task { [weak self] in
            for await r in results {
                guard let self else { break }
                self.recordResult(r)
            }
        }
    }

    public func stop() async {
        watcherTask?.cancel()
        watcherTask = nil
        batchTask?.cancel()
        batchTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        fullSyncTask?.cancel()
        fullSyncTask = nil
        if let janitor = trashJanitor {
            await janitor.stop()
        }
        await watcher.stopAll()
        await syncActor.close()
        state = .idle
    }

    /// User-trigger path for Tier 3 (on-demand) — runs an immediate full sync
    /// of a target. Phase 6 will hook this to a UI button.
    public func triggerFullSync(_ target: SyncTarget) async {
        let job = SyncJob(target: target, direction: .push, priority: .normal,
                          tier: .onDemand, isFullSync: true)
        await syncActor.enqueue(job)
    }

    /// SYNC-RECONCILE: enqueue a full sync for every currently-watched
    /// target. This is what converges unchanged-but-divergent files; the
    /// per-subdir explosion in `FileSyncActor.enqueue` keeps each rsync
    /// bounded and `--delete` scoped to a subtree.
    public func triggerFullSyncAll() async {
        for target in watchedTargets {
            await triggerFullSync(target)
        }
    }

    // MARK: - Periodic full sync (SYNC-RECONCILE)

    private func startPeriodicFullSync() {
        guard fullSyncInterval > .zero, !watchedTargets.isEmpty else { return }
        fullSyncTask?.cancel()
        fullSyncTask = Task { [weak self] in
            guard let self else { return }
            // Hold the first reconciliation until a peer is actually
            // configured — FileSyncActor silently drops jobs while
            // `peer == nil` (pre-pair / mid-restore), so firing too early
            // would waste the initial full sync.
            try? await Task.sleep(for: self.initialFullSyncDelay)
            await self.awaitPeerReady(timeout: .seconds(120))
            while !Task.isCancelled {
                await self.triggerFullSyncAll()
                try? await Task.sleep(for: self.fullSyncInterval)
            }
        }
    }

    /// Poll `FileSyncActor.peer` until it's non-nil or the timeout elapses.
    /// Returns regardless; the caller proceeds either way (a still-nil peer
    /// just means the full sync is dropped and the next tick retries).
    private func awaitPeerReady(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await syncActor.peer != nil { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Internals

    private func routeWatcherBatch(_ batch: FileWatcherActor.Output) async {
        switch batch.tier {
        case .realtime:
            let job = SyncJob(
                target: batch.target,
                paths: batch.paths,
                direction: .push,
                priority: .high,
                tier: .realtime
            )
            await syncActor.enqueue(job)
        case .batched:
            await batchAccumulator.accumulate(paths: batch.paths, for: batch.target)
        case .onDemand:
            // Skip — on-demand only fires from user/schedule triggers.
            break
        }
    }

    private func recordResult(_ r: SyncResult) {
        if case .success = r.status {
            lastSyncTimes[r.target] = Date()
        }
        // v1.1 UX: don't surface pre-pair "no peer configured" failures in
        // Recent Activity. FileSyncActor now silently drops jobs when peer
        // is nil, but this defends against any leftover path that still
        // produces that string.
        if case .failure(let reason) = r.status, reason.contains("no peer configured") {
            return
        }
        recentResults.insert(r.status, at: 0)
        if recentResults.count > 20 { recentResults.removeLast() }
    }
}
