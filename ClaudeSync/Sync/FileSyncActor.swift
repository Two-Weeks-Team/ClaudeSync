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

    public let config: Configuration
    public let watcher: FileWatcherActor?
    public let peer: RsyncCommandBuilder.PeerEndpoint?

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
    public func enqueue(_ job: SyncJob) {
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
        // We don't get the rsync child's PID until ProcessRunner exposes it;
        // for now use a synthetic identifier per job (the watcher only cares
        // that the path is suppressed for this period).
        let fakePid = pid_t(abs(job.id.hashValue) % 100_000 + 1)
        if let watcher {
            await watcher.registerRsyncProcess(pid: fakePid, for: writePathSet)
        }

        let outcome: SyncResult.ResultStatus
        var stderrText = ""
        do {
            let out = try await runner.run()
            if out.exitCode == 0 {
                outcome = .success
            } else {
                outcome = .partialSuccess(transferredCount: 0, failedCount: 0)
                stderrText = out.stderrString
            }
        } catch let ProcessRunner.RunnerError.nonZeroExit(code, stderr) {
            outcome = .failure(reason: "rsync exit=\(code)")
            stderrText = stderr
        } catch ProcessRunner.RunnerError.cancelled {
            outcome = .cancelled
        } catch {
            outcome = .failure(reason: String(describing: error))
        }

        if let watcher {
            await watcher.unregisterRsyncProcess(pid: fakePid, for: writePathSet)
        }

        await emit(.init(
            jobId: job.id, target: job.target, status: outcome,
            duration: started.duration(to: .now),
            stderr: stderrText
        ))
        await markFinished(job)
    }

    private func markFinished(_ job: SyncJob) async {
        runningIDs.remove(job.id)
        scheduleNext()
    }

    private func emit(_ result: SyncResult) async {
        resultsContinuation.yield(result)
    }
}
