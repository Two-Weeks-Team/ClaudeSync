import Foundation
import os

/// Abstraction over the bidirectional control plane between two ClaudeSync
/// peers. Implementations:
/// * ``NWConnectionPeerChannel`` — production, wraps NWConnection +
///   ``ClaudeSyncProtocolFramer``.
/// * ``LoopbackPeerChannel`` — in-process loopback used by unit tests so
///   ``PairingManager`` can be exercised without spinning up NWListener.
///
/// `incomingMessages()` is hot — once you start iterating you receive every
/// message that arrives from that point on. A single subscriber is assumed;
/// PairingManager owns the iteration.
public protocol PeerChannel: Sendable {
    /// Encode and send a control message to the remote peer.
    func send(_ message: ControlMessage) async throws

    /// Stream of decoded control messages received from the remote peer.
    /// Finishes when ``close()`` is invoked or the underlying transport drops.
    func incomingMessages() -> AsyncStream<ControlMessage>

    /// Close the channel; subsequent `send` calls throw.
    func close() async
}

// MARK: - Loopback test double

/// In-process peer-channel pair. Anything `a.send()`s arrives on
/// `b.incomingMessages()` and vice versa. Use this in tests to drive
/// PairingManager without standing up a network listener.
///
/// Build a connected pair with ``LoopbackPeerChannel/makePair()``.
public final class LoopbackPeerChannel: PeerChannel, @unchecked Sendable {
    public enum LoopbackError: Error, Sendable, Equatable {
        case channelClosed
        case partnerNotConnected
    }

    fileprivate struct State {
        var continuation: AsyncStream<ControlMessage>.Continuation?
        var isClosed = false
        var sendLog: [ControlMessage] = []
    }

    fileprivate let state = OSAllocatedUnfairLock(initialState: State())
    private weak var partner: LoopbackPeerChannel?

    public init() {}

    /// Build a connected pair `(a, b)` where each end's sends arrive on the
    /// other end's stream.
    public static func makePair() -> (LoopbackPeerChannel, LoopbackPeerChannel) {
        let a = LoopbackPeerChannel()
        let b = LoopbackPeerChannel()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    public func send(_ message: ControlMessage) async throws {
        let proceed = state.withLock { st -> Bool in
            guard !st.isClosed else { return false }
            st.sendLog.append(message)
            return true
        }
        guard proceed else { throw LoopbackError.channelClosed }
        guard let partner else { throw LoopbackError.partnerNotConnected }
        partner.deliver(message)
    }

    public func incomingMessages() -> AsyncStream<ControlMessage> {
        AsyncStream<ControlMessage> { continuation in
            self.state.withLock { st in
                st.continuation?.finish()
                st.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { st in st.continuation = nil }
            }
        }
    }

    public func close() async {
        let cont = state.withLock { st -> AsyncStream<ControlMessage>.Continuation? in
            st.isClosed = true
            let c = st.continuation
            st.continuation = nil
            return c
        }
        cont?.finish()

        // Tear down the partner's stream as well so its iterator unblocks.
        if let partnerCont = partner?.state.withLock({ st -> AsyncStream<ControlMessage>.Continuation? in
            let c = st.continuation
            st.continuation = nil
            return c
        }) {
            partnerCont.finish()
        }
    }

    // MARK: - Test introspection

    /// Messages this side has sent, in order. Useful in assertions.
    public var sentMessages: [ControlMessage] {
        state.withLock { $0.sendLog }
    }

    // MARK: - Internal

    private func deliver(_ message: ControlMessage) {
        let cont = state.withLock { $0.continuation }
        cont?.yield(message)
    }
}
