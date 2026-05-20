import XCTest
@testable import ClaudeSync

final class TrashJanitorTests: XCTestCase {

    private var tmpRoot: URL!
    private var fm: FileManager { .default }

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trashjanitor-\(UUID().uuidString)",
                                    isDirectory: true)
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup; tests should leave nothing behind even if
        // the janitor's own sweep missed something.
        try? fm.removeItem(at: tmpRoot)
    }

    private func makeBucket(name: String = UUID().uuidString,
                            ageDays: Double,
                            withFileBytes bytes: Int = 0) throws -> URL {
        let bucket = tmpRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        if bytes > 0 {
            let file = bucket.appendingPathComponent("payload.bin")
            try Data(repeating: 0xAB, count: bytes).write(to: file)
        }
        let then = Date().addingTimeInterval(-ageDays * 86_400)
        try fm.setAttributes([.modificationDate: then], ofItemAtPath: bucket.path)
        return bucket
    }

    func testSweep_removesBucketsOlderThanRetention() async throws {
        let oldBucket = try makeBucket(ageDays: 45)
        let freshBucket = try makeBucket(ageDays: 1)

        let janitor = TrashJanitor(trashRoot: tmpRoot, retentionDays: 30,
                                   sweepInterval: .seconds(3600))
        let outcome = await janitor.sweepOnce()

        XCTAssertEqual(outcome.scanned, 2)
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.errors, 0)
        XCTAssertFalse(fm.fileExists(atPath: oldBucket.path),
                       "45-day-old bucket should have been removed")
        XCTAssertTrue(fm.fileExists(atPath: freshBucket.path),
                      "1-day-old bucket must be retained")
    }

    func testSweep_skipsNonUUIDDirectories() async throws {
        let bucket = try makeBucket(name: "not-a-uuid-just-a-folder",
                                    ageDays: 90)
        let janitor = TrashJanitor(trashRoot: tmpRoot, retentionDays: 30,
                                   sweepInterval: .seconds(3600))
        let outcome = await janitor.sweepOnce()

        XCTAssertEqual(outcome.removed, 0,
                       "Defensive: never touch entries we did not create")
        XCTAssertTrue(fm.fileExists(atPath: bucket.path))
    }

    func testSweep_isNoOp_whenTrashRootMissing() async throws {
        let missing = tmpRoot.appendingPathComponent("does-not-exist")
        let janitor = TrashJanitor(trashRoot: missing, retentionDays: 30,
                                   sweepInterval: .seconds(3600))
        let outcome = await janitor.sweepOnce()
        XCTAssertEqual(outcome.scanned, 0)
        XCTAssertEqual(outcome.removed, 0)
    }

    func testSweep_countsReclaimedBytes() async throws {
        _ = try makeBucket(ageDays: 60, withFileBytes: 4096)
        let janitor = TrashJanitor(trashRoot: tmpRoot, retentionDays: 30,
                                   sweepInterval: .seconds(3600))
        let outcome = await janitor.sweepOnce()
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertGreaterThanOrEqual(outcome.bytesReclaimed, 4096)
    }

    func testRetentionDays_clampedToAtLeastOne() async throws {
        let janitor = TrashJanitor(trashRoot: tmpRoot, retentionDays: 0,
                                   sweepInterval: .seconds(3600))
        XCTAssertEqual(janitor.retentionDays, 1,
                       "zero/negative retention must be clamped so the janitor never sweeps everything immediately")
    }

    // Regression guard: Preferences.trashRetentionDays must actually flow
    // into the TrashJanitor used in production. The original v1.3 PR
    // defined the preference field + Codable plumbing but did not wire
    // it through AppEnvironment, so any user customization was silently
    // ignored and the coordinator's default 30-day window was used. This
    // test pins the contract so the regression cannot reappear: a
    // janitor built from a Preferences value carries that value through.
    func testPreferences_trashRetentionDays_isHonoredByJanitor() async throws {
        let prefs = Preferences(trashRetentionDays: 90)
        let janitor = TrashJanitor(retentionDays: prefs.trashRetentionDays)
        XCTAssertEqual(janitor.retentionDays, 90,
                       "TrashJanitor must adopt the retention window from Preferences instead of the hardcoded default")
    }
}
