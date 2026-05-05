import Foundation

/// Verifies that macOS Remote Login (sshd) is enabled before the pairing
/// handshake begins. Without sshd both the SSH key exchange and every
/// subsequent rsync transfer would silently fail.
///
/// Reference: PRD FR-00 (lines 139-148) — the most common first-time failure
/// mode and must be caught with an actionable message.
public struct RemoteLoginPreflight: Sendable {
    public struct Outcome: Equatable, Sendable {
        public let local: SSHReachability
        public let peer: SSHReachability?

        /// Both sides ready (or peer not yet known and local is OK).
        public var isReady: Bool {
            guard local.sshDaemonResponded else { return false }
            if let peer { return peer.sshDaemonResponded }
            return true
        }

        /// Which side first blocks pairing. Surface this to the user with a
        /// "Open System Settings" deep-link.
        public var failingSide: FailingSide? {
            if !local.sshDaemonResponded { return .local(local) }
            if let peer, !peer.sshDaemonResponded { return .peer(peer) }
            return nil
        }
    }

    public enum FailingSide: Equatable, Sendable {
        case local(SSHReachability)
        case peer(SSHReachability)
    }

    public let checker: SSHConnectivityChecker
    public let timeoutSeconds: Int
    public let localProbeHost: String
    public let localProbePort: UInt16

    public init(
        checker: SSHConnectivityChecker = ProcessSSHConnectivityChecker(),
        timeoutSeconds: Int = 5,
        localProbeHost: String = "localhost",
        localProbePort: UInt16 = 22
    ) {
        self.checker = checker
        self.timeoutSeconds = timeoutSeconds
        self.localProbeHost = localProbeHost
        self.localProbePort = localProbePort
    }

    /// Probe only the local sshd. Used during the first-launch onboarding
    /// step before any peer has been discovered.
    public func checkLocalOnly() async -> Outcome {
        let local = await checker.check(
            host: localProbeHost, port: localProbePort, timeoutSeconds: timeoutSeconds
        )
        return Outcome(local: local, peer: nil)
    }

    /// Probe both sides. Local side is checked first so the user gets an
    /// immediately actionable error pointing at their own machine before we
    /// blame the peer.
    public func checkBothSides(peerHost: String, peerPort: UInt16 = 22) async -> Outcome {
        let local = await checker.check(
            host: localProbeHost, port: localProbePort, timeoutSeconds: timeoutSeconds
        )
        guard local.sshDaemonResponded else {
            return Outcome(local: local, peer: nil)
        }
        let peer = await checker.check(
            host: peerHost, port: peerPort, timeoutSeconds: timeoutSeconds
        )
        return Outcome(local: local, peer: peer)
    }
}
