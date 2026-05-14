import Foundation

/// Async wrapper around `Foundation.Process` for running rsync, ssh-keygen, brew, etc.
///
/// Three execution modes:
///   * ``run()`` — wait for completion and return captured stdout/stderr.
///   * ``runStreaming()`` — stream stdout line-by-line as `AsyncThrowingStream`.
///   * ``cancel()`` — terminate a running process.
///
/// The runner is an actor so PID/lifecycle state cannot race with cancel calls.
public actor ProcessRunner {
    public struct Output: Sendable {
        public let exitCode: Int32
        public let stdout: Data
        public let stderr: Data

        public var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        public var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    public enum RunnerError: Error, Sendable, Equatable {
        case launchFailed(String)
        case nonZeroExit(code: Int32, stderr: String)
        case cancelled
        /// v1.2.15: ``run(timeout:)`` reached the supplied deadline before the
        /// child process exited. The runner has already invoked
        /// ``cancel()`` to terminate the child; the duration in the
        /// associated value is the *configured* limit, not the real elapsed
        /// time. Callers can treat this distinctly from
        /// ``cancelled`` (which means the host task was cancelled).
        case timedOut(Duration)
    }

    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?

    private var currentProcess: Process?

    /// PID of the running child process, or nil before launch / after exit.
    /// v1.0.1 (CR-C2 / RCA-M11): exposed so callers can register the *real*
    /// PID with FileWatcherActor for echo suppression instead of synthesising
    /// a fake one.
    public var pid: pid_t? {
        guard let p = currentProcess, p.isRunning else { return nil }
        return p.processIdentifier
    }

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// Run process, wait for exit, and capture full stdout/stderr.
    /// Throws ``RunnerError/nonZeroExit`` when the exit status is non-zero.
    ///
    /// - Parameter timeout: When non-nil, the child is `terminate()`d and the
    ///   call throws ``RunnerError/timedOut(_:)`` if exit does not happen
    ///   within `timeout`. Required for rsync-over-ssh invocations where the
    ///   underlying rsync protocol can deadlock and ``run()`` without a
    ///   timeout would await forever (v1.2.15 regression cause).
    public func run(timeout: Duration? = nil) async throws -> Output {
        guard let timeout else {
            return try await runUntilExit()
        }
        return try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask { try await self.runUntilExit() }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Cancel the running child *before* throwing, so the
                // ``runUntilExit`` task can resolve its continuation and not
                // strand a process orphan.
                await self.cancel()
                throw RunnerError.timedOut(timeout)
            }
            do {
                let first = try await group.next()
                group.cancelAll()
                return first ?? Output(exitCode: -1, stdout: Data(), stderr: Data())
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Internal worker — same shape as the pre-v1.2.15 ``run()`` body.
    private func runUntilExit() async throws -> Output {
        let (process, stdoutPipe, stderrPipe) = try makeProcess()
        currentProcess = process

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { proc in
                    let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let exitCode = proc.terminationStatus
                    let output = Output(exitCode: exitCode, stdout: stdoutData, stderr: stderrData)

                    if exitCode == 0 {
                        continuation.resume(returning: output)
                    } else if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: RunnerError.cancelled)
                    } else {
                        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                        continuation.resume(
                            throwing: RunnerError.nonZeroExit(code: exitCode, stderr: stderrText)
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Stream stdout line-by-line. The stream finishes when the process exits;
    /// it throws ``RunnerError/nonZeroExit`` at completion if exit code != 0.
    public func runStreaming() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let runTask = Task {
                do {
                    let (process, stdoutPipe, stderrPipe) = try makeProcess()
                    currentProcess = process

                    let stdoutHandle = stdoutPipe.fileHandleForReading
                    let buffer = LineBuffer()

                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        for line in buffer.append(data) {
                            continuation.yield(line)
                        }
                    }

                    try process.run()
                    process.waitUntilExit()
                    stdoutHandle.readabilityHandler = nil

                    if let tail = buffer.flush() {
                        continuation.yield(tail)
                    }

                    let exitCode = process.terminationStatus
                    if exitCode == 0 {
                        continuation.finish()
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.finish(throwing: RunnerError.cancelled)
                    } else {
                        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                        continuation.finish(
                            throwing: RunnerError.nonZeroExit(code: exitCode, stderr: stderrText)
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                runTask.cancel()
                Task { await self.cancel() }
            }
        }
    }

    /// Terminate the running process if any.
    public func cancel() {
        guard let process = currentProcess, process.isRunning else { return }
        process.terminate()
    }

    // MARK: - Private

    private func makeProcess() throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        return (process, stdoutPipe, stderrPipe)
    }
}

/// Thread-safe accumulator that splits an incoming `Data` stream on newline
/// boundaries. `readabilityHandler` callbacks fire on arbitrary background
/// threads, so the buffer needs its own lock instead of being a captured `var`.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)

        var lines: [String] = []
        while let newlineIndex = data.firstIndex(of: 0x0A) {
            let lineData = data[..<newlineIndex]
            data.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let tail = String(data: data, encoding: .utf8)
        data.removeAll()
        return tail
    }
}
