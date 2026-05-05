import Foundation

/// Pure-Swift encoder/decoder for the length-prefixed JSON frame used by the
/// ClaudeSync control channel. Pulled out of `NWProtocolFramer` so the wire
/// format can be unit-tested without spinning up a real network connection.
///
/// Wire format:
/// ```
/// ┌──────────────────────┬──────────────────────────────────┐
/// │ Length (4 bytes, BE) │ JSON payload (UTF-8)             │
/// └──────────────────────┴──────────────────────────────────┘
/// ```
public struct FrameCodec: Sendable {
    public enum Error: Swift.Error, Sendable, Equatable {
        case messageTooLarge(size: Int, maxSize: Int)
        case truncatedHeader
        case truncatedPayload(declared: Int, actual: Int)
        case payloadTooLarge(declared: Int, maxSize: Int)
        case payloadEmpty
    }

    /// Hard cap matching `NWProtocolFramer` implementation. 1 MB is plenty
    /// for control messages (the largest is a `pairRequest` ~2 KB).
    public static let maxPayloadSize: Int = 1_048_576

    public let maxPayloadSize: Int

    public init(maxPayloadSize: Int = FrameCodec.maxPayloadSize) {
        self.maxPayloadSize = maxPayloadSize
    }

    // MARK: - Encode

    /// Build a single framed packet from a `ControlMessage`.
    public func encode(_ message: ControlMessage) throws -> Data {
        let payload = try Self.jsonEncoder.encode(message)
        return try frame(payload: payload)
    }

    /// Frame an arbitrary payload (handy for tests / non-ControlMessage uses).
    public func frame(payload: Data) throws -> Data {
        guard payload.count <= maxPayloadSize else {
            throw Error.messageTooLarge(size: payload.count, maxSize: maxPayloadSize)
        }
        guard payload.count > 0 else {
            throw Error.payloadEmpty
        }
        var out = Data(capacity: 4 + payload.count)
        var lengthBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    // MARK: - Decode

    /// Decode a single framed packet (must contain exactly one frame).
    public func decode(_ packet: Data) throws -> ControlMessage {
        let payload = try unframe(packet: packet)
        return try Self.jsonDecoder.decode(ControlMessage.self, from: payload)
    }

    /// Strip the 4-byte length header and return the JSON payload.
    public func unframe(packet: Data) throws -> Data {
        guard packet.count >= 4 else { throw Error.truncatedHeader }
        let length = packet.prefix(4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        let declared = Int(length)
        guard declared <= maxPayloadSize else {
            throw Error.payloadTooLarge(declared: declared, maxSize: maxPayloadSize)
        }
        let payload = packet.dropFirst(4)
        guard payload.count == declared else {
            throw Error.truncatedPayload(declared: declared, actual: payload.count)
        }
        return Data(payload)
    }

    // MARK: - Streaming

    /// Stateful frame extractor for byte streams. Hand it whatever bytes you
    /// just read off the connection; it will return zero or more complete
    /// frames and buffer any partial frame for the next call.
    public final class StreamReader: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let maxPayloadSize: Int

        public init(maxPayloadSize: Int = FrameCodec.maxPayloadSize) {
            self.maxPayloadSize = maxPayloadSize
        }

        /// Append bytes and return any complete payloads now available.
        public func append(_ chunk: Data) throws -> [Data] {
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            var out: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).withUnsafeBytes {
                    $0.load(as: UInt32.self).bigEndian
                }
                let declared = Int(length)
                if declared > maxPayloadSize {
                    throw Error.payloadTooLarge(declared: declared, maxSize: maxPayloadSize)
                }
                let totalNeeded = 4 + declared
                if buffer.count < totalNeeded { break }
                let payload = buffer.subdata(in: 4 ..< totalNeeded)
                buffer.removeSubrange(0 ..< totalNeeded)
                out.append(payload)
            }
            return out
        }

        /// Append bytes and return any complete `ControlMessage`s now available.
        public func appendDecodingMessages(_ chunk: Data) throws -> [ControlMessage] {
            try append(chunk).map { payload in
                try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: payload)
            }
        }

        public func bufferedByteCount() -> Int {
            lock.lock(); defer { lock.unlock() }
            return buffer.count
        }
    }

    // MARK: - Encoder/Decoder configuration

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
