import Foundation

public enum SyncDirection: String, Codable, Sendable {
    case push    // local → peer
    case pull    // peer → local
}

public enum SyncPriority: Int, Codable, Comparable, Sendable {
    case critical   = 0   // MCP configs (Claude Desktop won't function without)
    case high       = 1   // settings, hooks, memory
    case normal     = 2   // project files
    case low        = 3   // sessions, transcripts, package lists
    case background = 4   // bulk historical data

    public static func < (lhs: SyncPriority, rhs: SyncPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SyncJob: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let target: SyncTarget
    public var paths: Set<String>            // empty == full sync of target
    public let direction: SyncDirection
    public let priority: SyncPriority
    public let tier: SyncTier
    public let createdAt: ContinuousClock.Instant
    public let isFullSync: Bool
    public var retryCount: Int

    public init(
        id: UUID = UUID(),
        target: SyncTarget,
        paths: Set<String> = [],
        direction: SyncDirection,
        priority: SyncPriority = .normal,
        tier: SyncTier = .realtime,
        createdAt: ContinuousClock.Instant = .now,
        isFullSync: Bool = false,
        retryCount: Int = 0
    ) {
        self.id = id
        self.target = target
        self.paths = paths
        self.direction = direction
        self.priority = priority
        self.tier = tier
        self.createdAt = createdAt
        self.isFullSync = isFullSync || paths.isEmpty
        self.retryCount = retryCount
    }
}

public struct SyncResult: Sendable {
    public let jobId: UUID
    public let target: SyncTarget
    public let status: ResultStatus
    public let filesTransferred: Int
    public let bytesTransferred: Int64
    public let duration: Duration
    public let stderr: String

    public enum ResultStatus: Sendable, Equatable {
        case success
        case partialSuccess(transferredCount: Int, failedCount: Int)
        case failure(reason: String)
        case cancelled
    }

    public init(
        jobId: UUID, target: SyncTarget, status: ResultStatus,
        filesTransferred: Int = 0, bytesTransferred: Int64 = 0,
        duration: Duration = .zero, stderr: String = ""
    ) {
        self.jobId = jobId
        self.target = target
        self.status = status
        self.filesTransferred = filesTransferred
        self.bytesTransferred = bytesTransferred
        self.duration = duration
        self.stderr = stderr
    }
}

/// Min-heap-style priority queue keyed by `(priority, createdAt)`. Lower
/// priority raw value wins; FIFO within the same priority.
///
/// Backing store is a sorted array — fine for the queue sizes we expect
/// (low hundreds at most). If profiling later shows hotspots, swap for a
/// proper binary heap.
public struct SyncJobPriorityQueue: Sendable {
    private var jobs: [SyncJob] = []

    public init() {}

    public var isEmpty: Bool { jobs.isEmpty }
    public var count: Int { jobs.count }

    public mutating func enqueue(_ job: SyncJob) {
        let idx = jobs.firstIndex(where: { Self.outranks(job, $0) }) ?? jobs.endIndex
        jobs.insert(job, at: idx)
    }

    @discardableResult
    public mutating func dequeue() -> SyncJob? {
        jobs.isEmpty ? nil : jobs.removeFirst()
    }

    public func peek() -> SyncJob? { jobs.first }

    /// Remove a job by id (e.g. cancelled by user). Returns the removed job.
    @discardableResult
    public mutating func remove(id: UUID) -> SyncJob? {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        return jobs.remove(at: idx)
    }

    /// Find an existing queued job for the same (target, direction) so the
    /// caller can merge `paths` instead of enqueueing a duplicate.
    public func findMergeable(target: SyncTarget, direction: SyncDirection) -> SyncJob? {
        jobs.first(where: { $0.target == target && $0.direction == direction && !$0.isFullSync })
    }

    public mutating func mergePaths(into id: UUID, paths: Set<String>) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].paths.formUnion(paths)
    }

    public func snapshot() -> [SyncJob] { jobs }

    /// v1.1: drop every queued job. Used by FileSyncActor when the user
    /// un-pairs so we don't keep a backlog that would emit confusing
    /// failures the next time a peer is configured.
    public mutating func removeAll() {
        jobs.removeAll()
    }

    /// `lhs` outranks `rhs` if it has a strictly higher priority (lower raw),
    /// or the same priority but an earlier createdAt.
    static func outranks(_ lhs: SyncJob, _ rhs: SyncJob) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.createdAt < rhs.createdAt
    }
}
