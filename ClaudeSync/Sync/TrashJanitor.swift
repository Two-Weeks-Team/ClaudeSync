import Foundation

/// SAFETY-001 — periodic cleanup of the rsync-`--backup-dir` quarantine.
///
/// `RsyncCommandBuilder` routes every deletion through
/// `~/.claudesync/trash/<job-id>/` (on the *receiving* side of a sync) so
/// that a propagated cleanup or accidental `rm -rf` is recoverable. The
/// quarantine would otherwise grow without bound; this actor sweeps
/// top-level buckets whose mtime is older than `retentionDays` (default
/// 30) on a daily cadence.
///
/// Janitor is intentionally conservative:
/// - Only touches the top-level UUID-named buckets under `trashRoot`.
/// - Skips anything whose name is not a valid UUID (defensive: avoids
///   accidentally deleting a user-placed file at the trash root).
/// - Never walks above `trashRoot`.
/// - All failures are logged but never thrown; a flaky filesystem can
///   never crash the sync engine.
public actor TrashJanitor {

    /// Default `~/.claudesync/trash/` directory.
    public static func defaultTrashRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/trash", isDirectory: true)
    }

    // Configuration is immutable post-init and Sendable, so it's safe
    // to read from outside the actor without awaiting.
    public nonisolated let trashRoot: URL
    public nonisolated let retentionDays: Int
    public nonisolated let sweepInterval: Duration
    private nonisolated let logger: AppLogger
    private let fm = FileManager.default
    private var loopTask: Task<Void, Never>?

    public init(trashRoot: URL = TrashJanitor.defaultTrashRoot(),
                retentionDays: Int = 30,
                sweepInterval: Duration = .seconds(24 * 60 * 60),
                logger: AppLogger = .shared) {
        self.trashRoot = trashRoot
        self.retentionDays = max(1, retentionDays)
        self.sweepInterval = sweepInterval
        self.logger = logger
    }

    /// Start the daily sweep loop. Idempotent — calling twice is a no-op.
    /// The first sweep runs immediately, then once per `sweepInterval`.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sweepOnce()
                try? await Task.sleep(for: self.sweepInterval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Outcome of a sweep run. Returned for tests + telemetry; the live
    /// loop doesn't act on it beyond logging.
    public struct SweepOutcome: Equatable, Sendable {
        public let scanned: Int
        public let removed: Int
        public let bytesReclaimed: Int64
        public let errors: Int
    }

    /// Public for tests so they can call deterministically.
    @discardableResult
    public func sweepOnce() async -> SweepOutcome {
        var outcome = SweepOutcome(scanned: 0, removed: 0,
                                   bytesReclaimed: 0, errors: 0)
        guard fm.fileExists(atPath: trashRoot.path) else { return outcome }

        let cutoff = Date().addingTimeInterval(
            -Double(retentionDays) * 24 * 60 * 60)
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: trashRoot,
                includingPropertiesForKeys: [.contentModificationDateKey,
                                             .isDirectoryKey, .totalFileSizeKey],
                options: [.skipsHiddenFiles])
        } catch {
            logger.warning("TrashJanitor: failed to list \(trashRoot.path): \(error)",
                           category: "trash")
            return outcome
        }

        var scanned = 0
        var removed = 0
        var bytes: Int64 = 0
        var errors = 0
        for url in entries {
            scanned += 1
            // Defensive: only sweep UUID-named buckets we created.
            guard UUID(uuidString: url.lastPathComponent) != nil else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isDirectoryKey,
            ])
            guard values?.isDirectory == true else { continue }
            guard let mtime = values?.contentModificationDate else { continue }
            guard mtime < cutoff else { continue }

            let size = directorySize(url) ?? 0
            do {
                try fm.removeItem(at: url)
                removed += 1
                bytes += size
                logger.info("TrashJanitor: removed \(url.lastPathComponent) (\(size) bytes, mtime \(mtime))",
                            category: "trash")
            } catch {
                errors += 1
                logger.warning("TrashJanitor: removeItem failed for \(url.path): \(error)",
                               category: "trash")
            }
        }
        outcome = SweepOutcome(scanned: scanned, removed: removed,
                               bytesReclaimed: bytes, errors: errors)
        if removed > 0 || errors > 0 {
            logger.info("TrashJanitor: sweep done — scanned=\(scanned) removed=\(removed) bytes=\(bytes) errors=\(errors)",
                        category: "trash")
        }
        return outcome
    }

    private func directorySize(_ url: URL) -> Int64? {
        guard let it = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.totalFileSizeKey],
                                     options: [.skipsHiddenFiles]) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in it {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey])
            if let bytes = values?.totalFileSize {
                total += Int64(bytes)
            }
        }
        return total
    }
}
