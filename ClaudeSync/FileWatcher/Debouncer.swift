import Foundation

/// Per-path 2-second quiet-period debouncer. Each path keeps its own timer;
/// every new event for the same path resets that path's timer. Once a path
/// has gone quiet for `quietPeriod`, it is added to a ready set, and after a
/// short coalesce window the entire ready set is flushed downstream.
///
/// This is the Tier 1 path through the watcher pipeline (TECHNICAL_SPEC §11
/// L1900-1960, Momus R4). Behaviour:
///
///   * a single event → fires after 2 s,
///   * rapid events on the same path → timer keeps resetting, only fires 2 s
///     after the *last* event,
///   * events on different paths → fully independent timers,
///   * `cancelAll()` → drops every pending timer without emitting anything.
///
/// `quietPeriod` and `coalesceDelay` are injectable so tests can run with
/// millisecond budgets instead of seconds.
public actor Debouncer {

    public typealias Output = (target: SyncTarget, paths: Set<String>)

    private var pathTimers: [String: Task<Void, Never>] = [:]
    /// Track which target each pending path belongs to, since the quiet-
    /// period closure runs in its own Task and needs to know where to put
    /// the result.
    private var pathTargets: [String: SyncTarget] = [:]
    private var readyPaths: [SyncTarget: Set<String>] = [:]
    private var flushTimer: Task<Void, Never>?

    private let quietPeriod: Duration
    private let coalesceDelay: Duration
    private let continuation: AsyncStream<Output>.Continuation

    public init(
        quietPeriod: Duration = .seconds(2),
        coalesceDelay: Duration = .milliseconds(100),
        continuation: AsyncStream<Output>.Continuation
    ) {
        self.quietPeriod = quietPeriod
        self.coalesceDelay = coalesceDelay
        self.continuation = continuation
    }

    /// Stream-based factory: returns the (stream, debouncer) pair.
    public static func makeStream(
        quietPeriod: Duration = .seconds(2),
        coalesceDelay: Duration = .milliseconds(100)
    ) -> (AsyncStream<Output>, Debouncer) {
        var continuation: AsyncStream<Output>.Continuation!
        let stream = AsyncStream<Output> { c in continuation = c }
        let debouncer = Debouncer(
            quietPeriod: quietPeriod,
            coalesceDelay: coalesceDelay,
            continuation: continuation
        )
        return (stream, debouncer)
    }

    /// Schedule (or reset) the quiet-period timer for each path.
    public func addPaths(_ paths: Set<String>, for target: SyncTarget) {
        for path in paths {
            pathTimers[path]?.cancel()
            pathTargets[path] = target

            let qp = quietPeriod
            pathTimers[path] = Task { [weak self] in
                try? await Task.sleep(for: qp)
                guard !Task.isCancelled else { return }
                await self?.markReady(path: path)
            }
        }
    }

    /// Cancel every pending timer; nothing pending is emitted.
    public func cancelAll() {
        for t in pathTimers.values { t.cancel() }
        pathTimers.removeAll()
        pathTargets.removeAll()
        flushTimer?.cancel()
        flushTimer = nil
        readyPaths.removeAll()
    }

    /// Number of paths whose timers are still ticking. Test introspection.
    public var pendingPathCount: Int { pathTimers.count }

    /// Number of distinct targets currently awaiting flush.
    public var readyTargetCount: Int { readyPaths.count }

    // MARK: - Private

    private func markReady(path: String) {
        guard let target = pathTargets[path] else { return }
        pathTimers.removeValue(forKey: path)
        pathTargets.removeValue(forKey: path)
        readyPaths[target, default: []].insert(path)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let delay = coalesceDelay
        flushTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushReady()
        }
    }

    private func flushReady() {
        let snapshot = readyPaths
        readyPaths.removeAll()
        flushTimer = nil
        for (target, paths) in snapshot where !paths.isEmpty {
            continuation.yield((target, paths))
        }
    }
}
