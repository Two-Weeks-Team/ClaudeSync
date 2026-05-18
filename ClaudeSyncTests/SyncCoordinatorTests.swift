import XCTest
@testable import ClaudeSync

final class SyncCoordinatorTests: XCTestCase {

    @MainActor
    func testStartStop_lifecycle_returnsToIdle() async throws {
        let watcher = FileWatcherActor(config: .init(
            homeDirectory: FileManager.default.temporaryDirectory,
            debounceQuietPeriod: .milliseconds(100),
            debounceCoalesce: .milliseconds(20)
        ))
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let sync = FileSyncActor(
            config: .init(maxConcurrent: 1, builder: builder),
            peer: .init(sshAddress: "kim@unused.local")
        )
        let (batchStream, batch) = BatchAccumulator.makeStream(flushInterval: .seconds(60))
        let coord = SyncCoordinator(watcher: watcher, syncActor: sync,
                                    batchAccumulator: batch, batchStream: batchStream)

        XCTAssertEqual(coord.state, .idle)
        await coord.start(targets: [])  // empty target set: no streams to install
        XCTAssertEqual(coord.state, .watching)
        await coord.stop()
        XCTAssertEqual(coord.state, .idle)
    }

    @MainActor
    func testRecentResults_recordsLastN() async throws {
        let watcher = FileWatcherActor(config: .init(
            homeDirectory: FileManager.default.temporaryDirectory,
            debounceQuietPeriod: .milliseconds(50),
            debounceCoalesce: .milliseconds(20)
        ))
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let sync = FileSyncActor(
            config: .init(maxConcurrent: 2, builder: builder),
            peer: .init(sshAddress: "kim@unused.local")
        )
        let (batchStream, batch) = BatchAccumulator.makeStream(flushInterval: .seconds(60))
        let coord = SyncCoordinator(watcher: watcher, syncActor: sync,
                                    batchAccumulator: batch, batchStream: batchStream)
        await coord.start(targets: [])

        // Manually enqueue some jobs and let the result pump tick.
        for _ in 0..<3 {
            await sync.enqueue(SyncJob(target: .codexConfig, direction: .push))
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(coord.recentResults.count, 0,
            "Coordinator should have recorded sync results")
        await coord.stop()
    }

    @MainActor
    func testTriggerFullSync_enqueuesOnDemandJob() async throws {
        let watcher = FileWatcherActor(config: .init(
            homeDirectory: FileManager.default.temporaryDirectory
        ))
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let sync = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder),  // never run
            peer: .init(sshAddress: "kim@unused.local")
        )
        let (batchStream, batch) = BatchAccumulator.makeStream()
        let coord = SyncCoordinator(watcher: watcher, syncActor: sync,
                                    batchAccumulator: batch, batchStream: batchStream)

        await coord.triggerFullSync(.projects)

        // v1.2.17: a top-level full-sync is exploded into one chunk per
        // immediate subdirectory of basePath, each scoped via SyncJob.subpath
        // (still isFullSync, still onDemand). On an empty/no-subdir basePath
        // the explode falls through to a single original job. Either way
        // pendingCount must be ≥ 1; every chunk must carry the original
        // target+tier+isFullSync attributes.
        let pending = await sync.pendingCount
        XCTAssertGreaterThanOrEqual(pending, 1)
        let jobs = await sync.queueSnapshot() ?? []
        XCTAssertFalse(jobs.isEmpty)
        for job in jobs {
            XCTAssertEqual(job.target, .projects)
            XCTAssertTrue(job.isFullSync)
            XCTAssertEqual(job.tier, .onDemand)
        }
    }
}

// Test-only introspection helper.
extension FileSyncActor {
    func queueSnapshot() -> [SyncJob]? {
        // Reuse the priority queue's snapshot by accessing a hidden helper.
        Mirror(reflecting: self).children.compactMap { child in
            if child.label == "queue", let q = child.value as? SyncJobPriorityQueue {
                return q.snapshot()
            }
            return nil
        }.first
    }
}
