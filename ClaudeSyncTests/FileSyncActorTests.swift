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

        let job = SyncJob(target: .codexConfig, direction: .push)
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

        let job = SyncJob(target: .codexConfig, direction: .push)
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

    func testNoPeer_emitsFailureWithoutInvokingRsync() async throws {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let actor = FileSyncActor(
            config: .init(maxConcurrent: 1, builder: builder),
            peer: nil  // <-- no peer
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

        await actor.enqueue(SyncJob(target: .codexConfig, direction: .push))
        try await Task.sleep(for: .milliseconds(200))
        await actor.close()

        let results = await consumer.value
        guard case .failure(let reason) = results.first?.status else {
            return XCTFail()
        }
        XCTAssertTrue(reason.contains("no peer"))
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
}
