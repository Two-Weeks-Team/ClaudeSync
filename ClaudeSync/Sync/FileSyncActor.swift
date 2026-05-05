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

        public init(maxConcurrent: Int = 3, builder: RsyncCommandBuilder = RsyncCommandBuilder()) {
            self.maxConcurrent = maxConcurrent
            self.builder = builder
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
        if !job.isFullSync,
           let existing = queue.findMergeable(target: job.target, direction: job.direction) {
            queue.mergePaths(into: existing.id, paths: job.paths)
            logger.info("merged \(job.paths.count) paths into existing job \(existing.id)",
                        category: "sync")
        } else {
            queue.enqueue(job)
        }
        scheduleNext()
    }

    public var pendingCount: Int { queue.count }
    public var runningCount: Int { runningIDs.count }

    public func close() {
        resultsContinuation.finish()
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        while runningIDs.count < config.maxConcurrent, let next = queue.dequeue() {
            runningIDs.insert(next.id)
            Task { [weak self] in
                guard let self else { return }
                await self.execute(job: next)
            }
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
        guard let executable = args.first else { return }
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
            let out = try await runner.run()
            outcome = Self.classifyRsyncOutcome(out)
            if case .partialSuccess = outcome {
                stderrText = out.stderrString
            }
        } catch let ProcessRunner.RunnerError.nonZeroExit(code, stderr) {
            outcome = .failure(reason: "rsync exit=\(code)")
            stderrText = stderr
        } catch ProcessRunner.RunnerError.cancelled {
            outcome = .cancelled
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
        scheduleNext()
    }

    private func emit(_ result: SyncResult) async {
        resultsContinuation.yield(result)
    }
}
