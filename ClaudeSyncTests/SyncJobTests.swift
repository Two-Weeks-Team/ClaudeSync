import XCTest
@testable import ClaudeSync

final class SyncJobPriorityQueueTests: XCTestCase {

    func testEnqueueDequeue_orderedByPriorityThenFIFO() {
        var q = SyncJobPriorityQueue()
        let now = ContinuousClock.now

        let lowEarly  = SyncJob(target: .codexConfig,    direction: .push, priority: .low,    createdAt: now)
        let highLate  = SyncJob(target: .claudeConfig,   direction: .push, priority: .high,   createdAt: now.advanced(by: .seconds(1)))
        let critEvenLater = SyncJob(target: .claudeAppSupport, direction: .push, priority: .critical, createdAt: now.advanced(by: .seconds(2)))
        let highEarlier = SyncJob(target: .projects,     direction: .push, priority: .high,   createdAt: now.advanced(by: .milliseconds(500)))

        q.enqueue(lowEarly)
        q.enqueue(highLate)
        q.enqueue(critEvenLater)
        q.enqueue(highEarlier)

        XCTAssertEqual(q.dequeue()?.id, critEvenLater.id, "critical first regardless of arrival time")
        XCTAssertEqual(q.dequeue()?.id, highEarlier.id,   "earlier high before later high")
        XCTAssertEqual(q.dequeue()?.id, highLate.id)
        XCTAssertEqual(q.dequeue()?.id, lowEarly.id)
        XCTAssertNil(q.dequeue())
    }

    func testFindMergeable_returnsExistingJobForSameTargetDirection() {
        var q = SyncJobPriorityQueue()
        let a = SyncJob(target: .claudeConfig, paths: ["~/.claude/settings.json"], direction: .push)
        q.enqueue(a)

        let mergeable = q.findMergeable(target: .claudeConfig, direction: .push)
        XCTAssertEqual(mergeable?.id, a.id)

        let unrelated = q.findMergeable(target: .projects, direction: .push)
        XCTAssertNil(unrelated)
    }

    func testMergePaths_unionsPathsIntoExistingJob() {
        var q = SyncJobPriorityQueue()
        let job = SyncJob(target: .claudeConfig, paths: ["a"], direction: .push)
        q.enqueue(job)

        q.mergePaths(into: job.id, paths: ["b", "c"])

        XCTAssertEqual(q.peek()?.paths, ["a", "b", "c"])
    }

    func testRemoveById_returnsAndRemoves() {
        var q = SyncJobPriorityQueue()
        let a = SyncJob(target: .claudeConfig, direction: .push)
        let b = SyncJob(target: .codexConfig,  direction: .push)
        q.enqueue(a); q.enqueue(b)

        let removed = q.remove(id: a.id)
        XCTAssertEqual(removed?.id, a.id)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.peek()?.id, b.id)
    }

    func testFullSync_isMarkedWhenPathsEmpty() {
        let job = SyncJob(target: .claudeConfig, direction: .push)
        XCTAssertTrue(job.isFullSync)
    }

    func testIncrementalSync_isMarkedWhenPathsProvided() {
        let job = SyncJob(target: .claudeConfig, paths: ["foo"], direction: .push)
        XCTAssertFalse(job.isFullSync)
    }

    func testSyncPriority_ordering() {
        XCTAssertLessThan(SyncPriority.critical, SyncPriority.high)
        XCTAssertLessThan(SyncPriority.high, SyncPriority.normal)
        XCTAssertLessThan(SyncPriority.normal, SyncPriority.low)
        XCTAssertLessThan(SyncPriority.low, SyncPriority.background)
    }
}
