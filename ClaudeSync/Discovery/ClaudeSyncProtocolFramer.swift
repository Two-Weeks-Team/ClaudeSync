import Foundation
import Network

/// Network.framework custom framer that wraps each `NWConnection` send/receive
/// in the length-prefixed JSON envelope produced by ``FrameCodec``.
///
/// The actual byte parsing is delegated to the codec so the framer stays a
/// thin shim over Network.framework's input/output callbacks. This split lets
/// the wire format be exhaustively unit-tested without standing up a real
/// connection.
///
/// Reference: TECHNICAL_SPEC §4 (NWProtocolFramer: Length-Prefixed JSON),
/// lines 552-624.
public final class ClaudeSyncProtocolFramer: NWProtocolFramerImplementation {
    public static let definition = NWProtocolFramer.Definition(
        implementation: ClaudeSyncProtocolFramer.self
    )
    public static let label: String = "ClaudeSync"

    public init(framer: NWProtocolFramer.Instance) {}

    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    public func wakeup(framer: NWProtocolFramer.Instance) {}

    public func stop(framer: NWProtocolFramer.Instance) -> Bool { true }

    public func cleanup(framer: NWProtocolFramer.Instance) {}

    // MARK: - Input

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            // 1. Parse the 4-byte length header.
            var headerBuffer = Data(count: 4)
            let parsed = framer.parseInput(
                minimumIncompleteLength: 4,
                maximumLength: 4
            ) { (buffer, _) -> Int in
                guard let buffer, buffer.count >= 4 else { return 0 }
                headerBuffer = Data(bytes: buffer.baseAddress!, count: 4)
                return 4
            }
            guard parsed else { return 4 }

            let length = headerBuffer.withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            guard length > 0, length <= UInt32(FrameCodec.maxPayloadSize) else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }

            // 2. Hand the payload up. The dispatching connection turns it
            //    into an `NWConnection` receive callback.
            let message = NWProtocolFramer.Message(definition: Self.definition)
            let delivered = framer.deliverInputNoCopy(
                length: Int(length),
                message: message,
                isComplete: true
            )
            if !delivered { return 4 + Int(length) }
        }
    }

    // MARK: - Output

    public func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        var header = Data(count: 4)
        let length = UInt32(messageLength).bigEndian
        header.withUnsafeMutableBytes {
            $0.storeBytes(of: length, as: UInt32.self)
        }
        framer.writeOutput(data: header)

        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }
}
