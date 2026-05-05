import Foundation

/// Tier 2 accumulator: collects path batches over a 5-minute window and
/// flushes them in a single emission. Used for `~/.claude/sessions/` and
/// `~/.claude/transcripts/` which can accumulate hundreds of MB per hour but
/// don't need real-time propagation.
///
/// Reference: TECHNICAL_SPEC §3 (3-Tier Sync Architecture, lines 406-444),
/// Momus R4.
public actor BatchAccumulator {
    public typealias Output = (target: SyncTarget, paths: Set<String>)

    private let flushInterval: Duration
    private let continuation: AsyncStream<Output>.Continuation
    private var pending: [SyncTarget: Set<String>] = [:]
    private var flushTask: Task<Void, Never>?

    public init(
        flushInterval: Duration = .seconds(300),
        continuation: AsyncStream<Output>.Continuation
    ) {
        self.flushInterval = flushInterval
        self.continuation = continuation
    }

    /// Convenience factory.
    public static func makeStream(
        flushInterval: Duration = .seconds(300)
    ) -> (AsyncStream<Output>, BatchAccumulator) {
        var c: AsyncStream<Output>.Continuation!
        let stream = AsyncStream<Output> { c = $0 }
        let acc = BatchAccumulator(flushInterval: flushInterval, continuation: c)
        return (stream, acc)
    }

    public func accumulate(paths: Set<String>, for target: SyncTarget) {
        pending[target, default: []].formUnion(paths)
        scheduleFlush()
    }

    /// Force an immediate flush — for app quit / sleep / user-triggered sync.
    public func flushImmediately() {
        flushTask?.cancel()
        flushTask = nil
        flushSnapshot()
    }

    /// Number of targets with pending paths. Test introspection.
    public var pendingTargetCount: Int { pending.count }

    public func cancelAll() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
    }

    public func close() {
        cancelAll()
        continuation.finish()
    }

    // MARK: - Private

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = flushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushOnTimer()
        }
    }

    private func flushOnTimer() {
        flushTask = nil
        flushSnapshot()
    }

    private func flushSnapshot() {
        let snapshot = pending
        pending.removeAll()
        for (target, paths) in snapshot where !paths.isEmpty {
            continuation.yield((target, paths))
        }
    }
}
