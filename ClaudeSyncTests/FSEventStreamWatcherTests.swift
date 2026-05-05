import XCTest
@testable import ClaudeSync

/// Real FSEvents tests — create files in a temp dir and assert the watcher
/// observes them. The shared pattern in every test:
///   1. Start the watcher and a consumer Task BEFORE touching the filesystem
///      (otherwise the iterator may not be installed when events fire).
///   2. Mutate the directory.
///   3. Sleep briefly to give FSEvents/dispatch a chance to deliver.
///   4. Call `watcher.stop()` to terminate the AsyncStream so the consumer
///      task returns.
final class FSEventStreamWatcherTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSEventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// realpath(3) — needed because FSEvents reports canonical paths
    /// (e.g. `/private/var/...` not `/var/...`).
    static func realpath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let r = Darwin.realpath(path, &buf) else { return path }
        return String(cString: r)
    }

    private func runWatcher(
        on path: String,
        latency: CFTimeInterval = 0.05,
        settleMs: Int = 300,
        actionMs: Int = 800,
        action: () throws -> Void
    ) async rethrows -> [FSEventStreamWatcher.FSEvent] {
        let watcher = FSEventStreamWatcher()
        let stream = watcher.start(paths: [path], latency: latency)

        let consumer = Task<[FSEventStreamWatcher.FSEvent], Never> {
            var out: [FSEventStreamWatcher.FSEvent] = []
            for await ev in stream {
                out.append(ev)
                if out.count >= 32 { break }
            }
            return out
        }

        try? await Task.sleep(for: .milliseconds(settleMs))
        try action()
        try? await Task.sleep(for: .milliseconds(actionMs))
        watcher.stop()
        return await consumer.value
    }

    // MARK: - Tests

    func testFileCreate_isObserved() async throws {
        let resolvedRoot = Self.realpath(tempDir.path)
        let target = tempDir.appendingPathComponent("hello.txt")
        let resolvedTarget = Self.realpath(tempDir.path) + "/hello.txt"

        let events = try await runWatcher(on: resolvedRoot) {
            try "hi".write(to: target, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(events.contains(where: { $0.path == resolvedTarget }),
            "Expected event for \(resolvedTarget) — got: \(events.map(\.path))")
    }

    func testFileModify_isObserved() async throws {
        let target = tempDir.appendingPathComponent("modify.txt")
        try "before".write(to: target, atomically: true, encoding: .utf8)

        let resolvedRoot = Self.realpath(tempDir.path)
        let resolvedTarget = resolvedRoot + "/modify.txt"

        let events = try await runWatcher(on: resolvedRoot) {
            try "after".write(to: target, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(events.contains(where: { $0.path == resolvedTarget }))
    }

    func testFileDelete_isObserved() async throws {
        let target = tempDir.appendingPathComponent("del.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)

        let resolvedRoot = Self.realpath(tempDir.path)
        let resolvedTarget = resolvedRoot + "/del.txt"

        let events = try await runWatcher(on: resolvedRoot) {
            try FileManager.default.removeItem(at: target)
        }
        XCTAssertTrue(events.contains(where: { $0.path == resolvedTarget }))
    }

    func testStop_terminatesStreamWithoutEventsRequired() async {
        // Pure lifecycle test — stop() should always cleanly tear down even if
        // no filesystem changes ever occur.
        let watcher = FSEventStreamWatcher()
        let stream = watcher.start(paths: [Self.realpath(tempDir.path)], latency: 0.1)
        let consumer = Task<Int, Never> {
            var n = 0
            for await _ in stream { n += 1 }
            return n
        }
        try? await Task.sleep(for: .milliseconds(100))
        watcher.stop()
        let total = await withTimeout(seconds: 2) { await consumer.value } ?? -1
        XCTAssertGreaterThanOrEqual(total, 0, "Stream must have terminated cleanly after stop()")
    }
}
