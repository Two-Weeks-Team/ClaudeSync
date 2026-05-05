import Foundation
import CoreServices

/// Top-level file-change watcher. For each enabled `SyncTarget` it owns a
/// `FSEventStreamWatcher`, runs every event through `IgnorePatterns` 1차
/// 필터, then through a `Debouncer` (2 s per-path quiet-period). The output
/// stream is a sequence of `(SyncTarget, SyncTier, Set<String>)` ready for
/// `SyncCoordinator` to enqueue against `FileSyncActor` (Phase 5).
///
/// PID-based echo suppression API is exposed but the actual rsync writer
/// integration lands in Phase 5.
public actor FileWatcherActor {

    public typealias Output = (target: SyncTarget, tier: SyncTier, paths: Set<String>)

    public struct Configuration: Sendable {
        public let homeDirectory: URL
        public let ignore: IgnorePatterns
        public let debounceQuietPeriod: Duration
        public let debounceCoalesce: Duration
        public let fsEventsLatency: CFTimeInterval

        public init(
            homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
            ignore: IgnorePatterns = IgnorePatterns(),
            debounceQuietPeriod: Duration = .seconds(2),
            debounceCoalesce: Duration = .milliseconds(100),
            fsEventsLatency: CFTimeInterval = 0.3
        ) {
            self.homeDirectory = homeDirectory
            self.ignore = ignore
            self.debounceQuietPeriod = debounceQuietPeriod
            self.debounceCoalesce = debounceCoalesce
            self.fsEventsLatency = fsEventsLatency
        }
    }

    public let config: Configuration
    private var watchers: [SyncTarget: FSEventStreamWatcher] = [:]
    private var consumerTasks: [SyncTarget: Task<Void, Never>] = [:]
    private var rsyncPidsByPath: [String: Set<pid_t>] = [:]
    private var releaseBuffers: [String: ContinuousClock.Instant] = [:]

    private let debouncer: Debouncer
    private let debounceStream: AsyncStream<Debouncer.Output>
    private let outputStream: AsyncStream<Output>
    private let outputContinuation: AsyncStream<Output>.Continuation

    private var routerTask: Task<Void, Never>?
    private let logger = AppLogger.shared

    public init(config: Configuration = Configuration()) {
        self.config = config
        let (dStream, deb) = Debouncer.makeStream(
            quietPeriod: config.debounceQuietPeriod,
            coalesceDelay: config.debounceCoalesce
        )
        self.debouncer = deb
        self.debounceStream = dStream
        var outCont: AsyncStream<Output>.Continuation!
        self.outputStream = AsyncStream<Output> { c in outCont = c }
        self.outputContinuation = outCont
    }

    /// Public stream of (target, tier, paths) batches ready to sync.
    public nonisolated func changes() -> AsyncStream<Output> { outputStream }

    /// Start watching the given targets. Pulls each target's `watchPaths`,
    /// expands `~`, canonicalises via `realpath`, and registers an FSEvents
    /// stream for each.
    public func startWatching(targets: Set<SyncTarget>) async {
        await ensureRouterRunning()

        for target in targets {
            guard watchers[target] == nil else { continue }
            let spec = target.spec
            let absolutePaths = spec.watchPaths
                .map { $0.expandingTildeInPath }
                .map { Self.realpath($0) }
                .filter { !$0.isEmpty }

            // Skip targets whose root doesn't exist on this machine — common
            // for codexConfig if the user doesn't use Codex.
            let valid = absolutePaths.filter {
                FileManager.default.fileExists(atPath: $0)
            }
            guard !valid.isEmpty else {
                logger.warning("skipping target \(target.rawValue) — no watchable paths exist",
                               category: "watcher")
                continue
            }

            let watcher = FSEventStreamWatcher()
            watchers[target] = watcher
            let stream = watcher.start(paths: valid, latency: config.fsEventsLatency)

            // For each FSEvent, filter via ignore patterns + suppression, then
            // hand the raw path to the debouncer keyed by this target.
            consumerTasks[target] = Task { [weak self] in
                for await event in stream {
                    guard let self else { break }
                    await self.processEvent(event, for: target)
                }
            }
        }
    }

    public func stopWatching(target: SyncTarget) {
        watchers[target]?.stop()
        watchers.removeValue(forKey: target)
        consumerTasks[target]?.cancel()
        consumerTasks.removeValue(forKey: target)
    }

    public func stopAll() async {
        for target in Array(watchers.keys) {
            stopWatching(target: target)
        }
        await debouncer.cancelAll()
        routerTask?.cancel()
        routerTask = nil
        outputContinuation.finish()
    }

    // MARK: - PID-based echo suppression (Phase 5 integration)

    public func registerRsyncProcess(pid: pid_t, for paths: Set<String>) {
        for path in paths {
            rsyncPidsByPath[path, default: []].insert(pid)
        }
    }

    public func unregisterRsyncProcess(pid: pid_t, for paths: Set<String>) {
        for path in paths {
            rsyncPidsByPath[path]?.remove(pid)
            if rsyncPidsByPath[path]?.isEmpty == true {
                rsyncPidsByPath.removeValue(forKey: path)
                releaseBuffers[path] = .now
            }
        }
    }

    /// On startup: clean up stale `~/.claudesync/.syncing-<pid>` markers from
    /// crashed previous runs.
    public func cleanupStaleMarkers() {
        let dir = config.homeDirectory.appendingPathComponent(".claudesync", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(".syncing-") {
            let pidStr = url.lastPathComponent.replacingOccurrences(of: ".syncing-", with: "")
            if let pid = pid_t(pidStr), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Internals

    private func processEvent(_ event: FSEventStreamWatcher.FSEvent, for target: SyncTarget) async {
        let path = event.path

        // 1. Echo suppression: if a known rsync process is currently writing
        //    to this path (or we're inside its 1-second buffer), drop the event.
        if shouldSuppress(path: path) { return }

        // 2. Ignore patterns.
        if config.ignore.shouldIgnore(absolutePath: path, target: target) { return }

        // 3. Hand to the debouncer.
        await debouncer.addPaths([path], for: target)
    }

    private func shouldSuppress(path: String) -> Bool {
        if let pids = rsyncPidsByPath[path], !pids.isEmpty { return true }
        if let releaseTime = releaseBuffers[path] {
            if ContinuousClock.now - releaseTime < .seconds(1) { return true }
            releaseBuffers.removeValue(forKey: path)
        }
        return false
    }

    private func ensureRouterRunning() async {
        guard routerTask == nil else { return }
        let stream = debounceStream
        let continuation = outputContinuation
        routerTask = Task { [weak self] in
            for await batch in stream {
                guard self != nil else { break }
                let target = batch.target
                let baseAbs = Self.realpath(target.spec.basePath.expandingTildeInPath)
                // Group by tier so callers can priority-route.
                var byTier: [SyncTier: Set<String>] = [:]
                for absolutePath in batch.paths {
                    let relative = Self.relativePath(of: absolutePath, under: baseAbs) ?? ""
                    let tier = target.spec.tier(forRelativePath: relative)
                    byTier[tier, default: []].insert(absolutePath)
                }
                for (tier, paths) in byTier {
                    continuation.yield((target, tier, paths))
                }
            }
        }
    }

    static func relativePath(of absolutePath: String, under base: String) -> String? {
        guard absolutePath.hasPrefix(base) else { return nil }
        var rest = String(absolutePath.dropFirst(base.count))
        if rest.hasPrefix("/") { rest.removeFirst() }
        return rest
    }

    static func realpath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let r = Darwin.realpath(path, &buf) else { return path }
        return String(cString: r)
    }
}
