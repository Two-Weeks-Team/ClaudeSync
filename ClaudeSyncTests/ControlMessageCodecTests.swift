import XCTest
@testable import ClaudeSync

final class ControlMessageCodableTests: XCTestCase {
    func testPairRequest_roundtrips() throws {
        let original = ControlMessage.pairRequest(PairRequestPayload(
            machineId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            hostname: "MacBookPro",
            username: "kim",
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1... claudesync@MacBookPro",
            publicKeyFingerprint: "SHA256:abc123",
            protocolVersion: 1
        ))
        let data = try FrameCodec.jsonEncoder.encode(original)
        let decoded = try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPairAccept_roundtrips() throws {
        let original = ControlMessage.pairAccept(PairAcceptPayload(
            machineId: UUID(),
            hostname: "MacBookAir",
            username: "kim",
            publicKey: "ssh-ed25519 AAAA peer",
            publicKeyFingerprint: "SHA256:xyz",
            sshPort: 22
        ))
        let data = try FrameCodec.jsonEncoder.encode(original)
        let decoded = try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPairReject_roundtrips() throws {
        let original = ControlMessage.pairReject(reason: "user-declined")
        let data = try FrameCodec.jsonEncoder.encode(original)
        let decoded = try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testHeartbeat_roundtrips() throws {
        // Round to seconds — JSON ISO8601 doesn't preserve sub-second precision
        // by default, and equality on Date includes fractional seconds.
        let ts = Date(timeIntervalSince1970: 1_780_000_000)
        let original = ControlMessage.heartbeat(timestamp: ts)
        let data = try FrameCodec.jsonEncoder.encode(original)
        let decoded = try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDisconnect_roundtrips() throws {
        let original = ControlMessage.disconnect(reason: "user_unpair")
        let data = try FrameCodec.jsonEncoder.encode(original)
        let decoded = try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStatusRequest_roundtrips() throws {
        let original = ControlMessage.statusRequest
        let data = try FrameCodec.jsonEncoder.encode(original)
        let decoded = try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownTypeField_throwsDecodingError() {
        let bogus = Data(#"{"type":"SOMETHING_NEW","reason":"x"}"#.utf8)
        XCTAssertThrowsError(
            try FrameCodec.jsonDecoder.decode(ControlMessage.self, from: bogus)
        )
    }

    func testEncodedJSON_includesFlatTypeField() throws {
        let msg = ControlMessage.pairReject(reason: "no")
        let json = try FrameCodec.jsonEncoder.encode(msg)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"type\":\"pairReject\""), "Got: \(str)")
        XCTAssertTrue(str.contains("\"reason\":\"no\""))
    }
}

final class FrameCodecTests: XCTestCase {
    let codec = FrameCodec()

    // MARK: - Single packet

    func testFrameUnframe_roundtrips() throws {
        let payload = Data("hello world".utf8)
        let framed = try codec.frame(payload: payload)
        XCTAssertEqual(framed.count, 4 + payload.count)
        let unframed = try codec.unframe(packet: framed)
        XCTAssertEqual(unframed, payload)
    }

    func testHeader_isBigEndian() throws {
        let payload = Data(repeating: 0x41, count: 256)
        let framed = try codec.frame(payload: payload)
        // 256 == 0x00000100; in big-endian header bytes are 00 00 01 00.
        XCTAssertEqual(framed[0], 0x00)
        XCTAssertEqual(framed[1], 0x00)
        XCTAssertEqual(framed[2], 0x01)
        XCTAssertEqual(framed[3], 0x00)
    }

    func testFrame_rejectsEmptyPayload() {
        XCTAssertThrowsError(try codec.frame(payload: Data())) { error in
            XCTAssertEqual(error as? FrameCodec.Error, .payloadEmpty)
        }
    }

    func testFrame_rejectsOversizedPayload() {
        let small = FrameCodec(maxPayloadSize: 100)
        let payload = Data(repeating: 0xAA, count: 101)
        XCTAssertThrowsError(try small.frame(payload: payload)) { error in
            guard case .messageTooLarge(let size, let max) = error as? FrameCodec.Error else {
                return XCTFail("Expected .messageTooLarge, got \(error)")
            }
            XCTAssertEqual(size, 101)
            XCTAssertEqual(max, 100)
        }
    }

    func testUnframe_rejectsTruncatedHeader() {
        XCTAssertThrowsError(try codec.unframe(packet: Data([0x00, 0x01]))) { error in
            XCTAssertEqual(error as? FrameCodec.Error, .truncatedHeader)
        }
    }

    func testUnframe_rejectsTruncatedPayload() {
        // Header says 10 bytes but only 3 are present.
        let bad = Data([0x00, 0x00, 0x00, 0x0A]) + Data([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try codec.unframe(packet: bad)) { error in
            guard case .truncatedPayload(let declared, let actual) = error as? FrameCodec.Error else {
                return XCTFail("Expected .truncatedPayload, got \(error)")
            }
            XCTAssertEqual(declared, 10)
            XCTAssertEqual(actual, 3)
        }
    }

    func testEncodeDecode_realControlMessage() throws {
        let original = ControlMessage.heartbeat(timestamp: Date(timeIntervalSince1970: 1_780_000_000))
        let framed = try codec.encode(original)
        let decoded = try codec.decode(framed)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - StreamReader

    func testStreamReader_reassemblesAcrossChunks() throws {
        let reader = FrameCodec.StreamReader()
        let payload = Data("control plane chatter".utf8)
        let framed = try codec.frame(payload: payload)

        // Feed it in 3-byte chunks.
        var collected: [Data] = []
        for start in stride(from: 0, to: framed.count, by: 3) {
            let end = min(start + 3, framed.count)
            collected.append(contentsOf: try reader.append(framed.subdata(in: start ..< end)))
        }
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected.first, payload)
        XCTAssertEqual(reader.bufferedByteCount(), 0)
    }

    func testStreamReader_handlesMultipleFramesInOneRead() throws {
        let reader = FrameCodec.StreamReader()
        let a = try codec.frame(payload: Data("alpha".utf8))
        let b = try codec.frame(payload: Data("beta".utf8))
        let c = try codec.frame(payload: Data("gamma".utf8))
        let big = a + b + c

        let frames = try reader.append(big)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0], Data("alpha".utf8))
        XCTAssertEqual(frames[1], Data("beta".utf8))
        XCTAssertEqual(frames[2], Data("gamma".utf8))
    }

    func testStreamReader_decodesControlMessages() throws {
        let reader = FrameCodec.StreamReader()
        let m1 = ControlMessage.heartbeat(timestamp: Date(timeIntervalSince1970: 1_780_000_000))
        let m2 = ControlMessage.disconnect(reason: "bye")
        let bytes = try codec.encode(m1) + codec.encode(m2)

        let messages = try reader.appendDecodingMessages(bytes)
        XCTAssertEqual(messages, [m1, m2])
    }

    func testStreamReader_oversizedDeclaredLength_throws() {
        let reader = FrameCodec.StreamReader(maxPayloadSize: 16)
        // Header declares 100 bytes but max is 16 → reject before reading payload.
        let bogus = Data([0x00, 0x00, 0x00, 0x64])
        XCTAssertThrowsError(try reader.append(bogus)) { error in
            guard case .payloadTooLarge = error as? FrameCodec.Error else {
                return XCTFail("Expected .payloadTooLarge, got \(error)")
            }
        }
    }
}
