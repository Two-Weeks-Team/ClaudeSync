import Foundation

/// Outcome of a single ssh-reachability probe. The caller distinguishes between
/// "sshd answered" (any auth result) and "sshd is unreachable" (network or DNS).
public enum SSHReachability: Equatable, Sendable {
    /// `ssh ... "echo ok"` ran end-to-end and exited with 0.
    case ok
    /// sshd answered but rejected our credentials. **For preflight purposes
    /// this is also success** — it proves Remote Login is enabled. The user's
    /// own SSH key may simply not be installed yet (which is the normal
    /// pre-pairing state).
    case authFailed
    /// `Connection refused` — the host is reachable but no sshd is listening
    /// on the port. The user needs to enable Remote Login in System Settings.
    case connectionRefused(port: UInt16)
    /// `Connection timed out` or `Operation timed out` — host did not answer
    /// within the timeout budget.
    case connectionTimeout
    /// `Could not resolve hostname` / `Name or service not known` — DNS or
    /// .local hostname resolution failed.
    case hostUnreachable(host: String)
    /// Any other ssh failure mode (host key changed, kex error, etc.).
    case unknownError(String)

    /// Whether this outcome indicates the remote sshd is functional. For the
    /// preflight check, both `.ok` and `.authFailed` count as "sshd alive".
    public var sshDaemonResponded: Bool {
        switch self {
        case .ok, .authFailed:                 return true
        case .connectionRefused, .connectionTimeout,
             .hostUnreachable, .unknownError: return false
        }
    }
}

/// Pluggable SSH probe. Production uses ``ProcessSSHConnectivityChecker`` which
/// shells out to `/usr/bin/ssh`; tests use ``MockSSHConnectivityChecker`` to
/// inject every reachability case without a real sshd.
public protocol SSHConnectivityChecker: Sendable {
    func check(host: String, port: UInt16, timeoutSeconds: Int) async -> SSHReachability
}

// MARK: - Production implementation

/// Probes sshd by running `ssh -o BatchMode=yes -o ConnectTimeout=N -p PORT
/// HOST "echo ok"`. BatchMode prevents any password prompt so the probe always
/// completes within the timeout.
public struct ProcessSSHConnectivityChecker: SSHConnectivityChecker {
    public let executable: String

    public init(executable: String = "/usr/bin/ssh") {
        self.executable = executable
    }

    public func check(host: String, port: UInt16, timeoutSeconds: Int) async -> SSHReachability {
        let runner = ProcessRunner(
            executable: executable,
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=\(timeoutSeconds)",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-p", "\(port)",
                host,
                "echo ok",
            ]
        )

        do {
            let output = try await runner.run()
            return output.exitCode == 0 ? .ok : Self.classify(stderr: output.stderrString)
        } catch let ProcessRunner.RunnerError.nonZeroExit(_, stderr) {
            return Self.classify(stderr: stderr)
        } catch {
            return .unknownError(String(describing: error))
        }
    }

    /// Map ssh's stderr text to a structured reachability outcome.
    /// Exposed `internal` so the unit test can validate the parser without
    /// running real ssh.
    static func classify(stderr: String) -> SSHReachability {
        let s = stderr.lowercased()
        if s.contains("connection refused") {
            return .connectionRefused(port: 22)
        }
        if s.contains("connection timed out") || s.contains("operation timed out") {
            return .connectionTimeout
        }
        if s.contains("could not resolve hostname")
            || s.contains("name or service not known")
            || s.contains("nodename nor servname") {
            return .hostUnreachable(host: "")
        }
        if s.contains("permission denied") {
            return .authFailed
        }
        if s.contains("host key verification failed") {
            return .unknownError("Host key verification failed")
        }
        // sshd answered enough to negotiate but something else went wrong.
        // Still treat as "responded" for preflight by default? Conservative:
        // surface it as unknownError so the UI can show the raw message.
        return .unknownError(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Test double

/// Deterministic checker for unit tests. Configure once with the desired
/// reachability and the tests can verify how `RemoteLoginPreflight` reacts.
public actor MockSSHConnectivityChecker: SSHConnectivityChecker {
    private var scriptedResults: [String: SSHReachability]
    private var defaultResult: SSHReachability
    public private(set) var probedHosts: [(host: String, port: UInt16)] = []

    public init(default defaultResult: SSHReachability = .ok,
                scripted: [String: SSHReachability] = [:]) {
        self.defaultResult = defaultResult
        self.scriptedResults = scripted
    }

    public func setResult(_ result: SSHReachability, for host: String) {
        scriptedResults[host] = result
    }

    public func setDefault(_ result: SSHReachability) {
        defaultResult = result
    }

    public func check(host: String, port: UInt16, timeoutSeconds: Int) async -> SSHReachability {
        probedHosts.append((host, port))
        return scriptedResults[host] ?? defaultResult
    }
}
