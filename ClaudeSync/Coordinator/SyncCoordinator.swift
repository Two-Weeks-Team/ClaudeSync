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

    private var watcherTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    public init(
        watcher: FileWatcherActor,
        syncActor: FileSyncActor,
        batchAccumulator: BatchAccumulator,
        batchStream: AsyncStream<BatchAccumulator.Output>,
        conflictResolver: ConflictResolver = ConflictResolver()
    ) {
        self.watcher = watcher
        self.syncActor = syncActor
        self.batchAccumulator = batchAccumulator
        self.batchStream = batchStream
        self.conflictResolver = conflictResolver
    }

    // MARK: - Lifecycle

    public func start(targets: Set<SyncTarget> = [.claudeConfig, .claudeAppSupport, .codexConfig]) async {
        await watcher.startWatching(targets: targets)
        state = .watching

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
