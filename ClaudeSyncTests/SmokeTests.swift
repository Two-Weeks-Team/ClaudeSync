import XCTest
@testable import ClaudeSync

final class SmokeTests: XCTestCase {
    @MainActor
    func testAppEnvironmentInitializesWithIdleStatus() {
        let env = AppEnvironment()
        XCTAssertEqual(env.overallStatus, .idle)
    }

    func testProcessRunnerEchoesStdout() async throws {
        let runner = ProcessRunner(
            executable: "/bin/echo",
            arguments: ["hello", "claudesync"]
        )
        let output = try await runner.run()
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
                       "hello claudesync")
    }

    func testProcessRunnerSurfacesNonZeroExit() async {
        let runner = ProcessRunner(
            executable: "/bin/sh",
            arguments: ["-c", "exit 42"]
        )
        do {
            _ = try await runner.run()
            XCTFail("Expected nonZeroExit error")
        } catch let ProcessRunner.RunnerError.nonZeroExit(code, _) {
            XCTAssertEqual(code, 42)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoggerWritesToFile() throws {
        let logger = AppLogger()
        logger.info("smoke-test-marker", category: "smoke")

        // FileLogSink writes asynchronously; give the queue a moment.
        let logURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/logs/claudesync.log")
        let expectation = expectation(description: "log line written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if let contents = try? String(contentsOf: logURL, encoding: .utf8),
               contents.contains("smoke-test-marker") {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
