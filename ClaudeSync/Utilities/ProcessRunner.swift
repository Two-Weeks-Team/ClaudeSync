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
    ///
    /// v1.3.1 (SYNC-DEADLOCK): stdout and stderr are drained **as data
    /// arrives** via `readabilityHandler`, not lazily in `terminationHandler`.
    /// The old implementation only called `readToEnd()` after the child
    /// exited; a child that wrote more than the OS pipe buffer (~64KB on
    /// macOS) to stdout blocked on `write()` and never exited, so the handler
    /// never fired — a deadlock. rsync surfaced it as `poll: timeout`
    /// (exit 255) once its own `--timeout` elapsed, exactly what we saw on
    /// large `--itemize-changes` changesets after the v1.3 sync.
    ///
    /// The drain is event-driven (dispatch-source callbacks) rather than a
    /// blocking `readToEnd()` on a GCD worker: blocking three GCD threads per
    /// invocation (2 reads + waitUntilExit) starved the `.utility` thread pool
    /// on the few-core CI runner and hung the whole suite. `readabilityHandler`
    /// holds no thread. This mirrors the long-proven ``runStreaming`` path.
    /// The continuation resolves only once both pipes hit EOF *and* the process
    /// has terminated, so all output is captured with no read/exit race.
    private func runUntilExit() async throws -> Output {
        let (process, stdoutPipe, stderrPipe) = try makeProcess()
        currentProcess = process

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let coordinator = ExitCoordinator { exitCode, bySignal, stdout, stderr in
                    if exitCode == 0 {
                        continuation.resume(returning: Output(exitCode: exitCode, stdout: stdout, stderr: stderr))
                    } else if bySignal {
                        continuation.resume(throwing: RunnerError.cancelled)
                    } else {
                        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
                        continuation.resume(throwing: RunnerError.nonZeroExit(code: exitCode, stderr: stderrText))
                    }
                }

                outHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        coordinator.markStdoutEOF()
                    } else {
                        coordinator.appendStdout(data)
                    }
                }
                errHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        coordinator.markStderrEOF()
                    } else {
                        coordinator.appendStderr(data)
                    }
                }
                process.terminationHandler = { proc in
                    coordinator.markExited(code: proc.terminationStatus,
                                           bySignal: proc.terminationReason == .uncaughtSignal)
                }

                do {
                    try process.run()
                } catch {
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
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

/// Collects stdout/stderr and the exit status from independent dispatch-source
/// callbacks (two `readabilityHandler`s + one `terminationHandler`, each on its
/// own queue) and fires `onComplete` exactly once when all three have reported:
/// both pipes at EOF and the process terminated. This ordering guarantees every
/// byte the child wrote is captured before the exit code is reported — no
/// read-vs-exit race — without blocking any thread. (v1.3.1, SYNC-DEADLOCK.)
private final class ExitCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var bySignal = false
    private var fired = false
    private let onComplete: (Int32, Bool, Data, Data) -> Void

    init(onComplete: @escaping (Int32, Bool, Data, Data) -> Void) {
        self.onComplete = onComplete
    }

    func appendStdout(_ d: Data) { lock.lock(); stdout.append(d); lock.unlock() }
    func appendStderr(_ d: Data) { lock.lock(); stderr.append(d); lock.unlock() }
    func markStdoutEOF() { fireIfReady { $0.stdoutEOF = true } }
    func markStderrEOF() { fireIfReady { $0.stderrEOF = true } }
    func markExited(code: Int32, bySignal: Bool) {
        fireIfReady { $0.exited = true; $0.exitCode = code; $0.bySignal = bySignal }
    }

    /// Apply `mutate` under the lock, then fire `onComplete` (outside the lock)
    /// the first time all three conditions hold.
    private func fireIfReady(_ mutate: (ExitCoordinator) -> Void) {
        lock.lock()
        mutate(self)
        let shouldFire = !fired && stdoutEOF && stderrEOF && exited
        if shouldFire { fired = true }
        let out = stdout, err = stderr, code = exitCode, sig = bySignal
        lock.unlock()
        if shouldFire { onComplete(code, sig, out, err) }
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
