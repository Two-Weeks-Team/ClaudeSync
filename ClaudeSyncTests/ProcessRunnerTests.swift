import XCTest
@testable import ClaudeSync

final class ProcessRunnerTests: XCTestCase {

    // MARK: - SYNC-DEADLOCK (v1.3.1) — pipe-buffer drain regression

    /// Pre-v1.3.1 the runner only read stdout in `terminationHandler`, which
    /// never fired while a child blocked on `write()` after filling the
    /// ~64KB OS pipe buffer. rsync over a large `--itemize-changes` changeset
    /// hit this and died with `poll: timeout`. This pumps ~1.7MB through
    /// stdout (≫ the buffer); with the bug it deadlocks until the timeout
    /// fires, so the assertion on a clean exit code is the regression guard.
    func testRun_largeStdout_doesNotDeadlock() async throws {
        // 100k lines × 17 bytes ≈ 1.7MB.
        let runner = ProcessRunner(
            executable: "/bin/sh",
            arguments: ["-c", "yes 0123456789ABCDEF | head -n 100000"]
        )
        let out = try await runner.run(timeout: .seconds(30))
        XCTAssertEqual(out.exitCode, 0,
                       "large-stdout child must exit cleanly, not deadlock then time out")
        XCTAssertGreaterThan(out.stdout.count, 1_000_000,
                             "all stdout bytes must be captured, not just the first pipe-buffer's worth")
    }

    /// Same hazard on the stderr pipe — a child can fill stderr just as
    /// easily, and the old code also deferred that read to the handler.
    func testRun_largeStderr_doesNotDeadlock() async throws {
        let runner = ProcessRunner(
            executable: "/bin/sh",
            arguments: ["-c", "yes 0123456789ABCDEF | head -n 100000 1>&2"]
        )
        let out = try await runner.run(timeout: .seconds(30))
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertGreaterThan(out.stderr.count, 1_000_000)
    }

    /// Both pipes filled at once — verifies the two concurrent drains don't
    /// starve each other (which would reintroduce the deadlock on whichever
    /// pipe wasn't being read).
    func testRun_largeStdoutAndStderr_bothCaptured() async throws {
        let runner = ProcessRunner(
            executable: "/bin/sh",
            arguments: ["-c",
                        "yes OUT | head -n 80000 & yes ERR | head -n 80000 1>&2; wait"]
        )
        let out = try await runner.run(timeout: .seconds(30))
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertGreaterThan(out.stdout.count, 200_000)
        XCTAssertGreaterThan(out.stderr.count, 200_000)
    }

    // MARK: - Baseline behavior still intact

    func testRun_capturesStdout_andZeroExit() async throws {
        let runner = ProcessRunner(executable: "/bin/echo", arguments: ["hello"])
        let out = try await runner.run()
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual(out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testRun_nonZeroExit_throws() async throws {
        let runner = ProcessRunner(executable: "/bin/sh", arguments: ["-c", "exit 23"])
        do {
            _ = try await runner.run()
            XCTFail("expected nonZeroExit")
        } catch let ProcessRunner.RunnerError.nonZeroExit(code, _) {
            XCTAssertEqual(code, 23)
        }
    }

    /// A child that never exits must hit the timeout path and be terminated,
    /// not hang the caller forever.
    func testRun_timeout_terminatesHangingChild() async throws {
        let runner = ProcessRunner(executable: "/bin/sh", arguments: ["-c", "sleep 60"])
        do {
            _ = try await runner.run(timeout: .milliseconds(500))
            XCTFail("expected timedOut")
        } catch let ProcessRunner.RunnerError.timedOut(limit) {
            XCTAssertEqual(limit, .milliseconds(500))
        }
    }
}
