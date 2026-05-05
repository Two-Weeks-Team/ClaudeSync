import XCTest
@testable import ClaudeSync

final class LoopbackPeerChannelTests: XCTestCase {

    func testSend_arrivesOnPartnerStream() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()

        // Install the continuation BEFORE spawning the consumer task so the
        // send below cannot race ahead of the subscription.
        let stream = b.incomingMessages()
        let received = Task<ControlMessage?, Never> {
            for await msg in stream { return msg }
            return nil
        }

        try await a.send(.heartbeat(timestamp: Date(timeIntervalSince1970: 1_780_000_000)))

        let msg = await withTimeout(seconds: 2) { await received.value }
        XCTAssertEqual(msg, .heartbeat(timestamp: Date(timeIntervalSince1970: 1_780_000_000)))
    }

    func testBidirectional() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()

        let aStream = a.incomingMessages()
        let bStream = b.incomingMessages()
        let aReceived = Task<ControlMessage?, Never> {
            for await msg in aStream { return msg }
            return nil
        }
        let bReceived = Task<ControlMessage?, Never> {
            for await msg in bStream { return msg }
            return nil
        }

        try await a.send(.statusRequest)
        try await b.send(.disconnect(reason: "bye"))

        async let aMsg = await withTimeout(seconds: 2) { await aReceived.value }
        async let bMsg = await withTimeout(seconds: 2) { await bReceived.value }
        let (gotA, gotB) = await (aMsg, bMsg)

        XCTAssertEqual(gotA, .disconnect(reason: "bye"))
        XCTAssertEqual(gotB, .statusRequest)
    }

    func testClose_terminatesIncomingStream() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()

        let stream = b.incomingMessages()
        let drained = Task<Int, Never> {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }

        try await a.send(.statusRequest)
        try await Task.sleep(for: .milliseconds(50))
        await a.close()

        let total = await withTimeout(seconds: 2) { await drained.value } ?? -1
        XCTAssertEqual(total, 1, "Stream should have yielded the one message and then finished on close()")
    }

    func testSend_afterClose_throws() async throws {
        let (a, _) = LoopbackPeerChannel.makePair()
        await a.close()
        do {
            try await a.send(.statusRequest)
            XCTFail("Expected channelClosed")
        } catch LoopbackPeerChannel.LoopbackError.channelClosed {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSentMessages_recordsHistory() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()
        let stream = b.incomingMessages()
        let drain = Task<Void, Never> {
            for await _ in stream {}
        }

        try await a.send(.statusRequest)
        try await a.send(.heartbeat(timestamp: Date(timeIntervalSince1970: 0)))
        try await Task.sleep(for: .milliseconds(50))
        await a.close()
        _ = await drain.value

        XCTAssertEqual(a.sentMessages.count, 2)
        XCTAssertEqual(a.sentMessages.first, .statusRequest)
    }
}

// MARK: - Helpers

/// Race the operation against a timeout so a hung test fails fast instead of
/// blocking the suite.
@discardableResult
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
