import Foundation
import Network
import os

/// `PeerChannel` backed by a real `NWConnection` running the ClaudeSync
/// length-prefixed JSON framer. Used in production; tests prefer
/// ``LoopbackPeerChannel``.
public final class NWConnectionPeerChannel: PeerChannel, @unchecked Sendable {
    public enum ChannelError: Error, Sendable {
        case sendFailed(String)
        case notReady
        case closed
    }

    fileprivate struct State {
        var continuation: AsyncStream<ControlMessage>.Continuation?
        var isStarted = false
        var isClosed = false
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let logger = AppLogger.shared
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let reader = FrameCodec.StreamReader()

    public init(connection: NWConnection,
                queue: DispatchQueue = DispatchQueue(label: "claudesync.peer-channel")) {
        self.connection = connection
        self.queue = queue
    }

    // MARK: - PeerChannel

    public func send(_ message: ControlMessage) async throws {
        let closed = state.withLock { $0.isClosed }
        guard !closed else { throw ChannelError.closed }

        let bytes = try FrameCodec().encode(message)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ChannelError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    public func incomingMessages() -> AsyncStream<ControlMessage> {
        AsyncStream<ControlMessage> { continuation in
            // CR-I2: extract the previous continuation from inside the lock,
            // then finish it AFTER releasing the lock — calling .finish()
            // can synchronously invoke onTermination, which re-acquires the
            // same non-reentrant unfair lock and would deadlock.
            struct Swap { var oldCont: AsyncStream<ControlMessage>.Continuation?; var alreadyStarted: Bool }
            let swap: Swap = self.state.withLock { st -> Swap in
                let prev = st.continuation
                st.continuation = continuation
                let already = st.isStarted
                st.isStarted = true
                return Swap(oldCont: prev, alreadyStarted: already)
            }
            swap.oldCont?.finish()
            let alreadyStarted = swap.alreadyStarted

            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { st in
                    // Only clear if it's still ours — a newer subscriber may
                    // have already replaced us.
                    if st.continuation != nil { st.continuation = nil }
                }
            }

            if !alreadyStarted {
                self.startStateMonitoring()
                self.connection.start(queue: self.queue)
            }
            self.scheduleReceive()
        }
    }

    public func close(reason: String) async {
        let (cont, didTransition) = state.withLock { st -> (AsyncStream<ControlMessage>.Continuation?, Bool) in
            guard !st.isClosed else { return (nil, false) }
            st.isClosed = true
            let c = st.continuation
            st.continuation = nil
            return (c, true)
        }
        guard didTransition else { return }   // already closed — don't re-log/re-cancel
        logger.info("peer channel closing — \(reason) [endpoint \(String(describing: connection.endpoint))]",
                    category: "discovery")
        cont?.finish()
        connection.cancel()
    }

    // MARK: - Internals

    private func startStateMonitoring() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let ifType = String(describing: self.connection.currentPath?.availableInterfaces.first?.type)
                self.logger.info("NWConnection ready [endpoint \(String(describing: self.connection.endpoint)), iface \(ifType)]",
                                 category: "discovery")
            case .waiting(let err):
                self.logger.info("NWConnection waiting: \(err.localizedDescription) [endpoint \(String(describing: self.connection.endpoint))]",
                                 category: "discovery")
            case .failed(let err):
                self.logger.warning("NWConnection failed: \(err.localizedDescription)", category: "discovery")
                Task { await self.close(reason: "NWConnection .failed: \(err.localizedDescription)") }
            case .cancelled:
                Task { await self.close(reason: "NWConnection .cancelled (something cancelled it)") }
            default:
                break
            }
        }
    }

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                do {
                    let messages = try self.reader.appendDecodingMessages(data)
                    let cont = self.state.withLock { $0.continuation }
                    for msg in messages { cont?.yield(msg) }
                } catch {
                    self.logger.warning("Frame decode failed: \(error)", category: "discovery")
                    Task { await self.close(reason: "frame decode failed: \(error)") }
                    return
                }
            }

            if let error {
                self.logger.warning("NWConnection receive error: \(error.localizedDescription)", category: "discovery")
                Task { await self.close(reason: "receive error: \(error.localizedDescription)") }
                return
            }

            // v1.2.13: do NOT close on `isComplete`. With NWProtocolFramer,
            // `isComplete: true` marks per-MESSAGE boundaries (set by our
            // framer's `deliverInputNoCopy(isComplete: true)` for every
            // length-prefixed frame), NOT connection-level FIN. Treating it
            // as FIN closed the channel after the first framed message —
            // which is exactly the pairRequest — surfacing as Air's
            // "send pairAccept failed: closed" right after `receivedPairRequest`.
            // Real connection close arrives via stateUpdateHandler .cancelled
            // or .failed, which is already handled in startStateMonitoring.

            self.scheduleReceive()
        }
    }
}
