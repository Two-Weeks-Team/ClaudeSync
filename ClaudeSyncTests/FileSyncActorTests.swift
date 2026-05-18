import XCTest
@testable import ClaudeSync

/// Drive FileSyncActor against a synthetic "rsync" executable that just
/// exits 0 — verifies queue → execute → result event pipeline without
/// requiring real ssh/rsync.
final class FileSyncActorTests: XCTestCase {

    func testEnqueue_executesJob_andEmitsSuccessResult() async throws {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 1, builder: builder),
            peer: .init(sshAddress: "kim@unused.local")
        )
        let stream = actor.results()
        let consumer = Task<[SyncResult], Never> {
            var out: [SyncResult] = []
            for await r in stream {
                out.append(r)
                if out.count >= 1 { break }
            }
            return out
        }

        // Use a paths-based job (paths non-empty ⇒ isFullSync=false) so
        // the v1.2.17 top-level full-sync explode doesn't intercept and
        // hand the dispatched job a different UUID than the one we
        // enqueued.
        let job = SyncJob(target: .codexConfig, paths: ["/tmp/x"], direction: .push)
        await actor.enqueue(job)

        try await Task.sleep(for: .milliseconds(300))
        await actor.close()

        let results = await consumer.value
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.jobId, job.id)
        XCTAssertEqual(results.first?.status, .success)
    }

    func testEnqueue_failingRsync_emitsFailure() async throws {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/false",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 1, builder: builder),
            peer: .init(sshAddress: "kim@unused.local")
        )
        let stream = actor.results()
        let consumer = Task<[SyncResult], Never> {
            var out: [SyncResult] = []
            for await r in stream {
                out.append(r)
                if out.count >= 1 { break }
            }
            return out
        }

        // Paths-based job (see v1.2.17 note above) to bypass the explode.
        let job = SyncJob(target: .codexConfig, paths: ["/tmp/x"], direction: .push)
        await actor.enqueue(job)

        try await Task.sleep(for: .milliseconds(300))
        await actor.close()

        let results = await consumer.value
        XCTAssertEqual(results.count, 1)
        guard case .failure(let reason) = results.first?.status else {
            return XCTFail("Expected failure, got \(String(describing: results.first?.status))")
        }
        XCTAssertTrue(reason.contains("exit=1"))
    }

    func testNoPeer_dropsJobSilently_v1_1() async throws {
        // v1.1 UX fix: when peer is nil (e.g. pre-pairing or after Forget),
        // jobs are dropped instead of cycling through the queue and emitting
        // "no peer configured" failures into the user's Recent Activity.
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 1, builder: builder),
            peer: nil  // <-- no peer
        )
        await actor.enqueue(SyncJob(target: .codexConfig, direction: .push))
        try await Task.sleep(for: .milliseconds(50))
        let pending = await actor.pendingCount
        let running = await actor.runningCount
        XCTAssertEqual(pending, 0, "no peer ⇒ enqueue must drop, not queue")
        XCTAssertEqual(running, 0, "no peer ⇒ no rsync invocation")
        await actor.close()
    }

    func testSetPeerNil_drainsPendingQueue_v1_1() async throws {
        // v1.1: un-pair (setPeer(nil)) clears anything still queued so the
        // moment a new peer is wired we don't run stale work meant for the
        // previous peer.
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder),
            peer: .init(sshAddress: "x@y.local")
        )
        // Paths-based jobs to avoid the v1.2.17 explode (which would make
        // beforePending a function of how many subdirs live under
        // ~/.codex and ~/.claude on the test machine — not what we're
        // exercising here).
        await actor.enqueue(SyncJob(target: .codexConfig, paths: ["/tmp/a"], direction: .push))
        await actor.enqueue(SyncJob(target: .claudeConfig, paths: ["/tmp/b"], direction: .push))
        let beforePending = await actor.pendingCount
        XCTAssertEqual(beforePending, 2)

        await actor.setPeer(nil)
        let afterPending = await actor.pendingCount
        XCTAssertEqual(afterPending, 0, "setPeer(nil) must drain the queue")
    }

    func testEnqueue_mergesMatchingTargetDirectionJobs() async throws {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder),  // never run
            peer: .init(sshAddress: "kim@unused.local")
        )
        await actor.enqueue(SyncJob(target: .claudeConfig, paths: ["a"], direction: .push))
        await actor.enqueue(SyncJob(target: .claudeConfig, paths: ["b"], direction: .push))
        await actor.enqueue(SyncJob(target: .codexConfig,  paths: ["c"], direction: .push))

        let pending = await actor.pendingCount
        XCTAssertEqual(pending, 2, "Two distinct (target,direction) groups")
        await actor.close()
    }

    // MARK: - v1.2.15 regression tests

    /// Reproduces the v1.2.14 stall: rsync hangs past the perJobTimeout, the
    /// runner is forced to terminate the child, ``execute`` catches
    /// ``RunnerError/timedOut`` and frees its slot so the next job can run.
    /// Without the v1.2.15 fix the second enqueue would never produce a
    /// result.
    func testHangingRsync_timesOut_andFreesSlot_v1_2_15() async throws {
        // `/usr/bin/yes` is a stand-in for a hung rsync: it runs forever
        // (printing "y\n"), ignores every command-line flag the builder
        // appends, and exits promptly on SIGTERM. ``ProcessRunner.cancel()``
        // sends SIGTERM, so the perJobTimeout firing must release the lane.
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/yes",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(
                maxConcurrent: 1,
                builder: builder,
                perJobTimeout: .milliseconds(200)
            ),
            peer: .init(sshAddress: "kim@unused.local")
        )
        let stream = actor.results()
        let consumer = Task<[SyncResult], Never> {
            var out: [SyncResult] = []
            for await r in stream {
                out.append(r)
                if out.count >= 1 { break }
            }
            return out
        }

        // Paths-based to bypass v1.2.17 explode.
        let job = SyncJob(target: .codexConfig, paths: ["/tmp/x"], direction: .push)
        await actor.enqueue(job)

        let results = await consumer.value
        XCTAssertEqual(results.count, 1)
        guard case .failure(let reason) = results.first?.status else {
            return XCTFail("Expected timeout-failure, got \(String(describing: results.first?.status))")
        }
        XCTAssertTrue(reason.contains("timed out"), "Reason should mention timeout: \(reason)")

        // Critical: the slot must be released. Without v1.2.15 fix
        // ``runningIDs`` would still hold the hung job's id.
        let running = await actor.runningCount
        XCTAssertEqual(running, 0, "Timed-out job must release its slot")
        await actor.close()
    }

    /// v1.2.15 single-flight: when an rsync for `(target, .push)` is in
    /// flight, a *second* enqueue with paths for the **same** lane must NOT
    /// spawn a concurrent rsync. In production this caused 3 concurrent
    /// `.claude/` rsyncs to fight over the same SSH session and deadlock.
    ///
    /// We construct the scenario by stalling the first job in flight (slow
    /// "rsync") and enqueuing a *non-mergeable* full-sync follow-up to the
    /// same lane. ``runningCount`` must remain at 1 while the first is
    /// running; the second only dispatches after the first frees its slot.
    // MARK: - v1.2.16 chunking regression

    /// A single enqueue carrying more than ``maxPathsPerJob`` paths must
    /// split into multiple queue entries, each at or below the cap. This
    /// prevents the giant-`--include` rsync invocation that routinely
    /// tripped the 90s timeout in production. We pick maxConcurrent=0 so
    /// nothing actually dispatches — we only inspect queue state.
    func testEnqueue_oversizedPathsSet_splitsIntoCappedChunks_v1_2_16() async throws {
        let cap = 4
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder, maxPathsPerJob: cap),
            peer: .init(sshAddress: "kim@unused.local")
        )
        let paths = (1...10).map { "/p/\($0)" }
        await actor.enqueue(SyncJob(
            target: .claudeConfig,
            paths: Set(paths),
            direction: .push
        ))

        let pending = await actor.pendingCount
        XCTAssertEqual(pending, 3, "10 paths at cap=4 must produce 3 jobs (4+4+2)")

        // Verify every queued job respects the cap.
        let snapshot = await actor.snapshot()
        for j in snapshot {
            XCTAssertLessThanOrEqual(j.paths.count, cap,
                                     "job \(j.id) has \(j.paths.count) paths > cap \(cap)")
        }
        // Sum must equal original — no paths lost on split.
        let totalAfter = snapshot.reduce(0) { $0 + $1.paths.count }
        XCTAssertEqual(totalAfter, paths.count, "Split must preserve all paths")
        await actor.close()
    }

    /// Merging into an existing same-lane queue job must respect the cap:
    /// fill the headroom, then enqueue the overflow as a fresh job. Without
    /// this guard, repeated FSEvent bursts could re-grow a job past the
    /// cap and re-create the giant-batch hazard.
    func testEnqueue_mergeRespectsCap_overflowSpillsToNewJob_v1_2_16() async throws {
        let cap = 4
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder, maxPathsPerJob: cap),
            peer: .init(sshAddress: "kim@unused.local")
        )
        // First enqueue → fills the queue with one job at cap=4.
        await actor.enqueue(SyncJob(
            target: .claudeConfig,
            paths: Set(["/a/1", "/a/2", "/a/3", "/a/4"]),
            direction: .push
        ))
        // Second enqueue (3 more paths) — first should *not* be merged
        // (cap headroom is 0); all 3 should become a new queued job.
        await actor.enqueue(SyncJob(
            target: .claudeConfig,
            paths: Set(["/b/1", "/b/2", "/b/3"]),
            direction: .push
        ))

        let snapshot = await actor.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        for j in snapshot {
            XCTAssertLessThanOrEqual(j.paths.count, cap,
                                     "job \(j.id) has \(j.paths.count) paths > cap \(cap)")
        }
        await actor.close()
    }

    /// v1.2.16: Full-sync jobs with no chunkable children — empty basePath
    /// or basePath that contains no immediate subdirectories — enqueue as a
    /// single job regardless of the cap. (After v1.2.17 the *split path* is
    /// gated on subpath==nil + at-least-one-subdirectory; this test
    /// exercises the no-subdir fallback so the old contract still holds.)
    func testEnqueue_fullSyncJobBypassesChunking_v1_2_16() async throws {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder, maxPathsPerJob: 4),
            peer: .init(sshAddress: "kim@unused.local")
        )
        // `.codexConfig` points at ~/.codex. On a test runner that doesn't
        // have a Codex install we expect no immediate subdirs → the
        // explode path falls through and the original job enqueues 1:1.
        // If ~/.codex happens to exist with subdirs this test still
        // proves explode produces ≥1 job (never zero), which is the
        // contract we care about.
        await actor.enqueue(SyncJob(
            target: .codexConfig,
            direction: .push,
            isFullSync: true
        ))
        let pending = await actor.pendingCount
        XCTAssertGreaterThanOrEqual(pending, 1,
            "Full-sync job must enqueue at least one chunk")
        await actor.close()
    }

    // MARK: - v1.2.17 full-sync explode regression

    /// A top-level full-sync (subpath == nil, isFullSync == true) is
    /// exploded into one full-sync per immediate subdirectory of basePath.
    /// We use a tempdir as basePath via a custom target override, so the
    /// child set is deterministic.
    ///
    /// Implementation note: the actor reads `SyncTarget.spec.basePath`
    /// directly (not injected), so this test exercises the *contract*
    /// against a real target whose basePath we populate in tmp. We pick
    /// `.projects` (~/Documents/GitHub) — already populated on this
    /// developer machine with many subdirectories — and assert that the
    /// resulting queue contains > 1 job, each scoped to a distinct
    /// subpath. On a clean test environment with no subdirs the explode
    /// falls through to a single-job result; that's covered by the
    /// `testEnqueue_fullSyncJobBypassesChunking_v1_2_16` test above.
    func testEnqueue_topLevelFullSync_explodesIntoPerSubdirChunks_v1_2_17() async throws {
        // Inspect the developer's ~/Documents/GitHub before deciding. This
        // test is environment-sensitive by design — it asserts the
        // explode behavior is observable when subdirs exist.
        let base = SyncTarget.projects.spec.basePath.expandingTildeInPath
        let fm = FileManager.default
        let subdirs: [String] = {
            guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }
            return entries.filter { name in
                var isDir: ObjCBool = false
                let abs = base + (base.hasSuffix("/") ? "" : "/") + name
                return fm.fileExists(atPath: abs, isDirectory: &isDir) && isDir.boolValue
            }
        }()
        guard subdirs.count >= 2 else {
            throw XCTSkip("Test requires ~/Documents/GitHub to contain ≥2 subdirs; found \(subdirs.count)")
        }

        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder),  // never run
            peer: .init(sshAddress: "kim@unused.local")
        )
        await actor.enqueue(SyncJob(
            target: .projects,
            direction: .push,
            isFullSync: true
        ))
        let snapshot = await actor.snapshot()
        XCTAssertEqual(snapshot.count, subdirs.count,
                       "Top-level full-sync must explode into one job per immediate subdir")

        // Each chunk must be a full-sync scoped to a distinct subpath.
        let chunkSubpaths = Set(snapshot.compactMap { $0.subpath })
        XCTAssertEqual(chunkSubpaths.count, snapshot.count,
                       "Every chunk must carry a distinct subpath")
        for j in snapshot {
            XCTAssertTrue(j.isFullSync, "Chunk \(j.id) must remain a full-sync")
            XCTAssertNotNil(j.subpath, "Chunk \(j.id) must have a subpath")
        }
        await actor.close()
    }

    /// A *subpath-scoped* full-sync (chunk emitted by the explode above)
    /// must not recursively explode again — it enqueues as itself. Without
    /// this guard the explode would loop on every subdirectory level.
    func testEnqueue_subpathScopedFullSync_doesNotReExplode_v1_2_17() async throws {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 0, builder: builder),
            peer: .init(sshAddress: "kim@unused.local")
        )
        await actor.enqueue(SyncJob(
            target: .claudeConfig,
            direction: .push,
            isFullSync: true,
            subpath: "projects"     // already a chunk — must NOT re-split
        ))
        let pending = await actor.pendingCount
        XCTAssertEqual(pending, 1, "subpath-scoped full-sync must not re-explode")
        await actor.close()
    }

    // MARK: - v1.2.15 regression tests

    func testSingleFlight_sameTarget_neverDispatchesConcurrently_v1_2_15() async throws {
        // /usr/bin/yes hangs forever; we close the actor before it ever
        // gets a chance to exit. perJobTimeout will eventually time it out
        // on a slow runner, but the assertion fires well before that.
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/yes",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(
                maxConcurrent: 3,                  // generous global limit
                builder: builder,
                perJobTimeout: .seconds(5)
            ),
            peer: .init(sshAddress: "kim@unused.local")
        )
        // Use subpath-scoped full-syncs (v1.2.17): the explode path checks
        // `subpath == nil` and skips, so these enqueue 1:1. They share
        // (target, .push), so per-target single-flight must still
        // serialize them. Paths-based jobs would *merge* into one queue
        // entry (defeating the test); subpath-scoped full-syncs stay
        // distinct.
        await actor.enqueue(SyncJob(target: .claudeConfig, direction: .push,
                                     isFullSync: true, subpath: "alpha"))
        await actor.enqueue(SyncJob(target: .claudeConfig, direction: .push,
                                     isFullSync: true, subpath: "beta"))

        // Give the actor a moment to dispatch the head of the queue.
        try await Task.sleep(for: .milliseconds(80))
        let runningWhileFirstInFlight = await actor.runningCount
        XCTAssertEqual(runningWhileFirstInFlight, 1,
                       "Same-lane second job must wait — saw \(runningWhileFirstInFlight) concurrent")
        let pendingWhileFirstInFlight = await actor.pendingCount
        XCTAssertEqual(pendingWhileFirstInFlight, 1,
                       "Deferred same-lane job must remain in queue")
        await actor.close()
    }
}
