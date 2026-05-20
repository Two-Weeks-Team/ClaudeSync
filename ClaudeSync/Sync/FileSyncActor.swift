import Foundation

/// Owns the priority queue of `SyncJob`s and runs them via rsync. Coordinates
/// PID-based echo suppression with `FileWatcherActor` so the writes rsync
/// performs on the receiver don't trigger an immediate sync-back.
///
/// Reference: TECHNICAL_SPEC §3 (Sync Protocol) + §11 (Sync Scheduling).
public actor FileSyncActor {

    public struct Configuration: Sendable {
        public let maxConcurrent: Int
        public let builder: RsyncCommandBuilder
        /// Hard ceiling on a single rsync invocation. The rsync protocol can
        /// deadlock (sender/receiver each waiting on the other) and the
        /// `--timeout=N` flag only catches *data-idle* — not the file-list
        /// negotiation phase. Without this ceiling, ``execute(job:)`` would
        /// await ``ProcessRunner/run(timeout:)`` forever and leak its
        /// ``runningIDs`` slot, eventually saturating ``maxConcurrent`` and
        /// stalling the entire engine (v1.2.14 regression).
        ///
        /// v1.3.1 (SYNC-DEADLOCK): raised 90s → 240s. This is the *outer*
        /// hard ceiling and must stay safely above rsync's own `--timeout`
        /// (now 120s, see RsyncCommandBuilder) so the inner data-idle timeout
        /// fires first with a clean `poll: timeout` instead of us SIGTERM-ing
        /// a job that is merely slow. v1.3's protect-filter + `--backup-dir`
        /// receiver work pushed full-tree syncs past the old 90s ceiling
        /// under bidirectional load, producing a permanent retry storm.
        /// Tests can shrink this without affecting behavior.
        public let perJobTimeout: Duration
        /// Maximum number of file paths an individual ``SyncJob`` (and thus
        /// a single rsync invocation) may carry. v1.2.15 fixed the leak that
        /// followed a deadlocked rsync; v1.2.16 attacks the *cause*: a
        /// merge-only ``BatchAccumulator`` would coalesce 60+ FSEvents into
        /// one giant `--include` list that took rsync minutes to negotiate
        /// and routinely tripped the 90s ceiling. Splitting at enqueue
        /// keeps each rsync small enough to finish well under the timeout,
        /// so the safety net never fires under normal load. Empirically
        /// 16 paths per chunk leaves headroom for the ~1.3KB per-include
        /// argv overhead and still allows a 256-path FSEvent burst to
        /// process in well under a minute on a LAN.
        public let maxPathsPerJob: Int

        public init(maxConcurrent: Int = 3,
                    builder: RsyncCommandBuilder = RsyncCommandBuilder(),
                    perJobTimeout: Duration = .seconds(240),
                    maxPathsPerJob: Int = 16) {
            self.maxConcurrent = maxConcurrent
            self.builder = builder
            self.perJobTimeout = perJobTimeout
            self.maxPathsPerJob = maxPathsPerJob
        }
    }

    public private(set) var config: Configuration
    public let watcher: FileWatcherActor?
    public private(set) var peer: RsyncCommandBuilder.PeerEndpoint?

    /// Update the peer endpoint after pairing completes. nil-out to revert to
    /// "no peer" state. v1.1: when nil-ing the peer (e.g. user clicked
    /// "Forget paired peer"), drop any pending jobs in the queue so they
    /// don't run and emit confusing failures the moment a peer is
    /// re-configured.
    public func setPeer(_ newPeer: RsyncCommandBuilder.PeerEndpoint?) {
        self.peer = newPeer
        if newPeer == nil {
            queue.removeAll()
            // runningIDs/runningTargets intentionally left untouched — the
            // in-flight tasks will resolve and emit failures (no peer / I/O
            // error) and call markFinished, which cleans them up.
        }
    }

    /// Swap the rsync command builder at runtime. Used by Settings to apply
    /// updated bandwidth/exclude preferences without restarting the engine.
    public func setBuilder(_ newBuilder: RsyncCommandBuilder) {
        self.config = Configuration(maxConcurrent: config.maxConcurrent,
                                    builder: newBuilder)
    }

    private var queue = SyncJobPriorityQueue()
    private var runningIDs: Set<UUID> = []
    /// v1.2.15: per-target+direction single-flight key. We never dispatch two
    /// concurrent rsync runs against the same `(target, direction)` because
    /// they fight over the same SSH session/remote path and were observed to
    /// deadlock in production (3 concurrent `.claude/` rsyncs hung for >5
    /// minutes, saturating ``runningIDs``). Tracked separately from
    /// ``runningIDs`` so the priority queue can still hold a *future* same-
    /// target job that will dispatch as soon as the current one finishes.
    private var runningTargets: Set<JobLane> = []
    /// Composite key matching ``SyncJobPriorityQueue.findMergeable`` semantics.
    private struct JobLane: Hashable {
        let target: SyncTarget
        let direction: SyncDirection
    }
    private let resultsContinuation: AsyncStream<SyncResult>.Continuation
    private let resultsStream: AsyncStream<SyncResult>
    private let logger = AppLogger.shared

    public init(
        config: Configuration = .init(),
        watcher: FileWatcherActor? = nil,
        peer: RsyncCommandBuilder.PeerEndpoint? = nil
    ) {
        self.config = config
        self.watcher = watcher
        self.peer = peer
        var c: AsyncStream<SyncResult>.Continuation!
        self.resultsStream = AsyncStream<SyncResult> { c = $0 }
        self.resultsContinuation = c
    }

    public nonisolated func results() -> AsyncStream<SyncResult> { resultsStream }

    /// Enqueue a job (or merge into an existing queued one for the same
    /// target+direction). Triggers scheduling so dispatch happens immediately
    /// when slots are free.
    ///
    /// v1.1: when no peer is configured (pre-pairing or after Forget),
    /// jobs are silently dropped instead of cycling through the queue and
    /// emitting "no peer configured" failures into the user's Recent
    /// Activity list. The next file change after pairing will enqueue
    /// fresh, so dropping pre-pair events costs nothing.
    public func enqueue(_ job: SyncJob) {
        guard peer != nil else {
            logger.info("dropping job \(job.id) for \(job.target.rawValue) — no peer paired yet",
                        category: "sync")
            return
        }
        // Full-sync jobs (paths is empty / isFullSync == true) used to be
        // un-chunkable: paths-based chunking doesn't help because rsync's
        // `--include` filter rules don't recurse into included directories
        // without the GNU-only `***` syntax that openrsync rejects. v1.2.17
        // takes a different route: at the *top-level* full-sync (subpath
        // == nil), we list `basePath`'s immediate child directories and
        // emit one full-sync *per subdirectory* (subpath = child). Each
        // per-subdir rsync is a regular full-sync of that smaller subtree,
        // `--delete` stays safely bounded inside the subtree, and the
        // v1.2.15 per-target single-flight serializes the resulting
        // children so the SSH session never fights itself. Top-level
        // new/delete is picked up by the next FSEvent (FSEvents fires on
        // the parent dir when its entries change).
        if job.isFullSync && job.subpath == nil {
            let base = job.target.spec.basePath.expandingTildeInPath
            let children = (try? FileManager.default
                .contentsOfDirectory(atPath: base)) ?? []
            // Only directories — files at top-level are handled by the
            // fallback path below (re-enqueued as a single full-sync).
            let fm = FileManager.default
            let subdirs = children.filter { name in
                var isDir: ObjCBool = false
                let absolute = base + (base.hasSuffix("/") ? "" : "/") + name
                return fm.fileExists(atPath: absolute, isDirectory: &isDir) && isDir.boolValue
            }
            if subdirs.isEmpty {
                // Empty / nothing to split — keep original behaviour.
                queue.enqueue(job)
                scheduleNext()
                return
            }
            for sub in subdirs {
                let chunk = SyncJob(
                    target: job.target,
                    paths: [],
                    direction: job.direction,
                    priority: job.priority,
                    tier: job.tier,
                    isFullSync: true,
                    retryCount: job.retryCount,
                    subpath: sub
                )
                queue.enqueue(chunk)
            }
            logger.info(
                "exploded top-level full-sync of \(job.target.rawValue) into \(subdirs.count) per-subdir chunks",
                category: "sync"
            )
            scheduleNext()
            return
        }
        // A subpath-scoped full-sync (already a chunk) or an unsplittable
        // full-sync (no children) enqueues as-is.
        guard !job.isFullSync else {
            queue.enqueue(job)
            scheduleNext()
            return
        }

        // v1.2.16: cap the path count per individual rsync invocation. The
        // per-target single-flight from v1.2.15 will serialize these chunks
        // through the same lane in deterministic order, and the smaller
        // `--include` lists negotiate fast enough that the 90s safety net
        // never fires under normal load. Pre-split the incoming paths
        // before consulting the merge target so an oversized merge can't
        // re-create the giant-batch hazard.
        let cap = max(1, config.maxPathsPerJob)

        // First, try to top up an existing queue-side job for the same lane
        // up to (but not past) the cap. This preserves the v1.1 coalescing
        // benefit for rapid FSEvent bursts without blowing the chunk size.
        var remaining = Array(job.paths)
        if let existing = queue.findMergeable(target: job.target, direction: job.direction) {
            let headroom = cap - existing.paths.count
            if headroom > 0 && !remaining.isEmpty {
                let take = min(headroom, remaining.count)
                let slice = Array(remaining.prefix(take))
                remaining.removeFirst(take)
                queue.mergePaths(into: existing.id, paths: Set(slice))
                logger.info(
                    "merged \(slice.count) paths into existing job \(existing.id) (lane=\(job.target.rawValue))",
                    category: "sync"
                )
            }
        }
        // Fast path: nothing got merged AND the whole job fits in one
        // chunk → enqueue the *original* job (preserving its UUID, which
        // callers — including FSEvent bookkeeping and tests — rely on for
        // result correlation). Only enter the splitting loop when we
        // actually need to split.
        if remaining.count == job.paths.count && remaining.count <= cap {
            queue.enqueue(job)
            scheduleNext()
            return
        }

        // Anything left over becomes one or more fresh queued jobs, each at
        // or below the cap. Same lane => v1.2.15's runningTargets gate
        // ensures they dispatch one-at-a-time.
        while !remaining.isEmpty {
            let take = min(cap, remaining.count)
            let chunk = Array(remaining.prefix(take))
            remaining.removeFirst(take)
            let sub = SyncJob(
                target: job.target,
                paths: Set(chunk),
                direction: job.direction,
                priority: job.priority,
                tier: job.tier,
                isFullSync: false,
                retryCount: job.retryCount
            )
            queue.enqueue(sub)
            logger.info(
                "chunk \(sub.id) (\(chunk.count) paths, lane=\(job.target.rawValue))",
                category: "sync"
            )
        }
        scheduleNext()
    }

    public var pendingCount: Int { queue.count }
    public var runningCount: Int { runningIDs.count }

    /// Read-only view of the queued (not yet dispatched) jobs in priority
    /// order. Exposed for tests and diagnostics; production code should not
    /// rely on the ordering or on capturing this snapshot.
    public func snapshot() -> [SyncJob] { queue.snapshot() }

    public func close() {
        resultsContinuation.finish()
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        // Dequeue while we have capacity AND the next job's lane is free.
        // If the head of the queue is for a lane that's already in flight,
        // we must NOT dispatch it — the receiving rsync would race the
        // in-flight one and could deadlock the SSH session (v1.2.14
        // production cause). Skip past it to look for a different-lane job,
        // and remember the skipped ones so we can put them back.
        var deferred: [SyncJob] = []
        while runningIDs.count < config.maxConcurrent, let next = queue.dequeue() {
            let lane = JobLane(target: next.target, direction: next.direction)
            if runningTargets.contains(lane) {
                deferred.append(next)
                continue
            }
            runningIDs.insert(next.id)
            runningTargets.insert(lane)
            Task { [weak self] in
                guard let self else { return }
                await self.execute(job: next)
            }
        }
        // Re-enqueue anything we skipped so a future scheduleNext (triggered
        // by markFinished) can pick it up. enqueue() would re-merge it with
        // any job that arrived in between, which is the behaviour we want.
        for job in deferred {
            queue.enqueue(job)
        }
    }

    private func execute(job: SyncJob) async {
        guard let peer else {
            await emit(.init(
                jobId: job.id, target: job.target,
                status: .failure(reason: "no peer configured"),
                stderr: "FileSyncActor.peer is nil"
            ))
            await markFinished(job)
            return
        }

        let args = config.builder.build(job: job, peer: peer)
        guard let executable = args.first else {
            // Defensive: an empty argv would mean the builder produced no
            // command, which shouldn't happen. Without this fix the slot in
            // ``runningIDs``/``runningTargets`` would leak forever (v1.2.15).
            await emit(.init(
                jobId: job.id, target: job.target,
                status: .failure(reason: "rsync builder returned empty argv"),
                stderr: "RsyncCommandBuilder.build returned []"
            ))
            await markFinished(job)
            return
        }
        AppLogger.shared.info("rsync argv: \(args.joined(separator: " "))", category: "sync")
        let runner = ProcessRunner(
            executable: executable,
            arguments: Array(args.dropFirst())
        )

        // Echo suppression: register every absolute path this rsync may write.
        let writePaths = job.paths.isEmpty
            ? [job.target.spec.basePath.expandingTildeInPath]
            : Array(job.paths)
        let writePathSet = Set(writePaths)

        let started = ContinuousClock.now
        // Use a job-id-derived sentinel as the PID key. The receiver-side
        // rsync (spawned by sshd on the other Mac) is the actual process
        // touching files, and we can't observe its PID from here — that's
        // why FileWatcherActor's authoritative loop-prevention runs through
        // the mtime-stale filter (CR-C2). The PID-based marker remains as a
        // local "do not push these paths *while we're sending them*" hint.
        // Use UUID instead of hashValue to avoid collisions across jobs.
        let markerPid = pid_t(truncatingIfNeeded:
            (UInt64(bitPattern: Int64(job.id.uuid.0))
                ^ UInt64(bitPattern: Int64(job.id.uuid.1))) & 0x7fff_ffff
        )
        if let watcher {
            await watcher.registerRsyncProcess(pid: markerPid, for: writePathSet)
        }

        let outcome: SyncResult.ResultStatus
        var stderrText = ""
        do {
            let out = try await runner.run(timeout: config.perJobTimeout)
            outcome = Self.classifyRsyncOutcome(out)
            if case .partialSuccess = outcome {
                stderrText = out.stderrString
            }
        } catch let ProcessRunner.RunnerError.nonZeroExit(code, stderr) {
            outcome = .failure(reason: "rsync exit=\(code)")
            stderrText = stderr
            AppLogger.shared.warning("rsync exit=\(code) stderr: \(stderr.prefix(800))",
                                     category: "sync")
        } catch ProcessRunner.RunnerError.cancelled {
            outcome = .cancelled
        } catch let ProcessRunner.RunnerError.timedOut(limit) {
            // v1.2.15: rsync hung past our perJobTimeout. ProcessRunner has
            // already called cancel() on the child. Mark this attempt as a
            // failure so the slot frees and a follow-up FSEvent can retry,
            // and log loudly so it's obvious in Recent Activity rather than
            // a silent stall.
            outcome = .failure(reason: "rsync timed out after \(limit)")
            AppLogger.shared.warning(
                "rsync timed out after \(limit) — terminated child; lane will retry on next FSEvent",
                category: "sync"
            )
        } catch let ProcessRunner.RunnerError.launchFailed(reason) {
            outcome = .failure(reason: "rsync launch failed: \(reason)")
        } catch {
            outcome = .failure(reason: String(describing: error))
        }

        if let watcher {
            await watcher.unregisterRsyncProcess(pid: markerPid, for: writePathSet)
        }

        await emit(.init(
            jobId: job.id, target: job.target, status: outcome,
            duration: started.duration(to: .now),
            stderr: stderrText
        ))
        await markFinished(job)
    }

    /// Decide whether an rsync invocation that returned exit code 0 actually
    /// transferred anything. v1.0.1 (CR-C3): exit 0 with zero transfers can
    /// mask malformed `--include` patterns, missing source paths, or
    /// receiver-side denial — so we count itemize-changes lines (`<`/`>`)
    /// in stdout. No transfer bytes ⇒ partial success ("nothing to do") so
    /// the UI doesn't show a misleading "✅ Synced just now".
    static func classifyRsyncOutcome(_ out: ProcessRunner.Output) -> SyncResult.ResultStatus {
        guard out.exitCode == 0 else {
            return .partialSuccess(transferredCount: 0, failedCount: 0)
        }
        let stdout = out.stdoutString
        if stdout.isEmpty {
            return .success  // No itemize output captured — assume nothing to sync, not an error.
        }
        // Itemize-changes lines start with `>` (receive) or `<` (send) followed
        // by a flag string. Any other line (e.g. "sending incremental file list")
        // is informational.
        var transferred = 0
        for line in stdout.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(">") || s.hasPrefix("<") {
                transferred += 1
            }
        }
        if transferred == 0 {
            // Exit 0 with no itemized changes is genuinely "up to date" —
            // count as success, but the caller can choose to stay silent.
            return .success
        }
        return .success
    }

    private func markFinished(_ job: SyncJob) async {
        runningIDs.remove(job.id)
        runningTargets.remove(JobLane(target: job.target, direction: job.direction))
        scheduleNext()
    }

    private func emit(_ result: SyncResult) async {
        resultsContinuation.yield(result)
    }
}
