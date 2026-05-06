import XCTest
@testable import ClaudeSync

/// Integration tests for FileWatcherActor — wires real FSEvents +
/// IgnorePatterns + Debouncer through the full pipeline.
///
/// We use a temporary home directory and watch a single hand-crafted target
/// rooted under it. To do this, we add a custom SyncTargetSpec via the
/// provided IgnorePatterns userExtra; the existing SyncTarget enum is reused
/// (we map onto `.codexConfig` for the test, since its spec is the leanest).
final class FileWatcherActorTests: XCTestCase {

    var tempHome: URL!
    var codexDir: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)", isDirectory: true)
        codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    /// Use a tight debounce so tests run quickly.
    private func makeActor() -> FileWatcherActor {
        FileWatcherActor(config: .init(
            homeDirectory: tempHome,
            debounceQuietPeriod: .milliseconds(80),
            debounceCoalesce: .milliseconds(20),
            fsEventsLatency: 0.05
        ))
    }

    /// SyncTarget.codexConfig.spec.basePath is `~/.codex`, which expands
    /// against the *real* HOME via NSHomeDirectory(). Override in the test by
    /// pre-creating a `.codex` under tempHome and `setenv("HOME", ...)`.
    override func invokeTest() {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        // Set HOME for the duration of this test so `~/.codex` expands here.
        let newHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherHOME-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: newHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: newHome + "/.codex", withIntermediateDirectories: true)
        setenv("HOME", newHome, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
            try? FileManager.default.removeItem(atPath: newHome)
        }
        super.invokeTest()
    }

    func testFileCreate_inWatchedTarget_emitsBatch() async throws {
        try Self.skipIfFSEventsHeadless()
        let actor = makeActor()
        let stream = actor.changes()
        let consumer = Task<[FileWatcherActor.Output], Never> {
            var out: [FileWatcherActor.Output] = []
            for await batch in stream {
                out.append(batch)
                if out.count >= 1 { break }
            }
            return out
        }

        await actor.startWatching(targets: [.codexConfig])
        try await Task.sleep(for: .milliseconds(300))

        // Create a file under HOME/.codex
        let codexPath = NSHomeDirectory() + "/.codex/settings.json"
        try "{}".write(toFile: codexPath, atomically: true, encoding: .utf8)

        // Wait long enough for the event → debounce → router pipeline to fire.
        try await Task.sleep(for: .milliseconds(400))
        await actor.stopAll()

        let batches = await consumer.value
        XCTAssertGreaterThan(batches.count, 0, "Expected at least one debounced batch")
        guard let first = batches.first else { return XCTFail() }
        XCTAssertEqual(first.target, .codexConfig)
        XCTAssertEqual(first.tier, .realtime)
        XCTAssertTrue(first.paths.contains(where: { $0.hasSuffix("/.codex/settings.json") }),
            "Got paths: \(first.paths)")
    }

    func testIgnoredFile_isFilteredOut() async throws {
        try Self.skipIfFSEventsHeadless()
        let actor = makeActor()
        let stream = actor.changes()
        let consumer = Task<[FileWatcherActor.Output], Never> {
            var out: [FileWatcherActor.Output] = []
            for await batch in stream {
                out.append(batch)
                if out.count >= 5 { break }
            }
            return out
        }

        await actor.startWatching(targets: [.codexConfig])
        try await Task.sleep(for: .milliseconds(300))

        // *.log is in IgnorePatterns.global → must not produce a batch.
        let logPath = NSHomeDirectory() + "/.codex/debug.log"
        try "noise".write(toFile: logPath, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(400))
        await actor.stopAll()

        let batches = await consumer.value
        let suspect = batches.flatMap { $0.paths }.filter { $0.hasSuffix("debug.log") }
        XCTAssertEqual(suspect.count, 0, "*.log should be filtered before debouncer")
    }

    func testEchoSuppression_dropsEventsForActiveRsyncPID() async throws {
        try Self.skipIfFSEventsHeadless()
        let actor = makeActor()
        let stream = actor.changes()
        let consumer = Task<[FileWatcherActor.Output], Never> {
            var out: [FileWatcherActor.Output] = []
            for await batch in stream {
                out.append(batch)
                if out.count >= 5 { break }
            }
            return out
        }

        await actor.startWatching(targets: [.codexConfig])
        try await Task.sleep(for: .milliseconds(300))

        // Pretend an rsync process is writing to this path right now.
        let writtenPath = FileWatcherActor.realpath(NSHomeDirectory() + "/.codex/settings.json")
        await actor.registerRsyncProcess(pid: 99999, for: [writtenPath])

        try "{}".write(toFile: NSHomeDirectory() + "/.codex/settings.json",
                       atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(400))
        await actor.stopAll()

        let batches = await consumer.value
        let leaked = batches.flatMap { $0.paths }.filter { $0 == writtenPath }
        XCTAssertEqual(leaked.count, 0, "Path under active rsync write must be suppressed")
    }

    func testRelativePath_helper() {
        XCTAssertEqual(
            FileWatcherActor.relativePath(of: "/Users/kim/.claude/sessions/x.jsonl",
                                          under: "/Users/kim/.claude"),
            "sessions/x.jsonl"
        )
        XCTAssertEqual(
            FileWatcherActor.relativePath(of: "/somewhere/else/file",
                                          under: "/Users/kim/.claude"),
            nil
        )
    }

    /// FSEvents requires a real filesystem-backed agent in the system.
    /// On GitHub Actions macos-15 runners FSEvents either doesn't fire or
    /// fires with significant lag, so the three event-driven tests above
    /// are skipped under CI to avoid flakiness. They still run on every
    /// developer Mac.
    static func skipIfFSEventsHeadless() throws {
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil
            || env["GITHUB_ACTIONS"] != nil
            || env["CLAUDESYNC_SKIP_FSEVENTS"] == "1"
        {
            throw XCTSkip("FSEvents is unreliable in headless CI environments")
        }
    }
}
