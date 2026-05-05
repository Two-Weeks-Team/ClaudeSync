import XCTest
@testable import ClaudeSync

/// End-to-end pairing tests using two PairingManagers connected via a
/// LoopbackPeerChannel pair. Each side gets its own temporary home dir so
/// authorized_keys writes are sandboxed.
final class PairingManagerTests: XCTestCase {

    var initiatorHome: URL!
    var responderHome: URL!
    var initiatorKeys: SSHKeyManager!
    var responderKeys: SSHKeyManager!
    var initiatorChannel: LoopbackPeerChannel!
    var responderChannel: LoopbackPeerChannel!
    var initiator: PairingManager!
    var responder: PairingManager!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        initiatorHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingTests-\(id)-A", isDirectory: true)
        responderHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingTests-\(id)-B", isDirectory: true)
        try FileManager.default.createDirectory(at: initiatorHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: responderHome, withIntermediateDirectories: true)

        initiatorKeys = SSHKeyManager(homeDirectoryURL: initiatorHome, machineLabel: "MacA")
        responderKeys = SSHKeyManager(homeDirectoryURL: responderHome, machineLabel: "MacB")

        let pair = LoopbackPeerChannel.makePair()
        initiatorChannel = pair.0
        responderChannel = pair.1

        initiator = PairingManager(
            channel: initiatorChannel,
            sshKeys: initiatorKeys,
            identity: .init(machineId: UUID(), hostname: "MacA", username: "kim", sshPort: 22)
        )
        responder = PairingManager(
            channel: responderChannel,
            sshKeys: responderKeys,
            identity: .init(machineId: UUID(), hostname: "MacB", username: "kim", sshPort: 22)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: initiatorHome)
        try? FileManager.default.removeItem(at: responderHome)
    }

    // MARK: - Happy path

    func testHappyPath_bothSidesReachCompleted_andCodesMatch() async throws {
        try await initiator.start()
        try await responder.start()

        // 1. Initiator sends pairRequest.
        try await initiator.initiate()
        try await waitUntil(seconds: 2) {
            if case .receivedPairRequest = await self.responder.state { return true }
            return false
        }

        // 2. Capture responder code, then accept.
        guard case .receivedPairRequest(_, let responderCode) = await responder.state else {
            return XCTFail("Responder should be in receivedPairRequest")
        }
        try await responder.acceptPendingRequest()

        // 3. Wait for initiator to receive pairAccept.
        try await waitUntil(seconds: 2) {
            if case .receivedPairAccept = await self.initiator.state { return true }
            return false
        }

        guard case .receivedPairAccept(_, let initiatorCode) = await initiator.state else {
            return XCTFail("Initiator should be in receivedPairAccept")
        }
        XCTAssertEqual(initiatorCode, responderCode,
            "Both sides must compute the same 6-digit code")
        XCTAssertEqual(initiatorCode.count, 6)

        // 4. Initiator confirms the code.
        try await initiator.confirmCode()

        try await waitUntil(seconds: 2) {
            if case .completed = await self.initiator.state,
               case .completed = await self.responder.state { return true }
            return false
        }

        // 5. Verify both authorized_keys files now contain the peer key.
        let aAuth = try String(
            contentsOf: await initiatorKeys.authorizedKeysURL, encoding: .utf8
        )
        let bAuth = try String(
            contentsOf: await responderKeys.authorizedKeysURL, encoding: .utf8
        )
        XCTAssertTrue(aAuth.contains("claudesync@MacB"),
            "Initiator must have installed responder's key")
        XCTAssertTrue(bAuth.contains("claudesync@MacA"),
            "Responder must have installed initiator's key")
    }

    // MARK: - Reject paths

    func testResponderRejects_initiatorTransitionsToRejected() async throws {
        try await responder.start()
        try await initiator.start()
        try await initiator.initiate()

        try await waitUntil(seconds: 2) {
            if case .receivedPairRequest = await self.responder.state { return true }
            return false
        }

        try await responder.reject(reason: "user-declined")

        try await waitUntil(seconds: 2) {
            if case .rejected = await self.initiator.state,
               case .rejected = await self.responder.state { return true }
            return false
        }

        // Neither side should have installed any key.
        let aAuthExists = FileManager.default.fileExists(atPath: await initiatorKeys.authorizedKeysURL.path)
        let bAuthExists = FileManager.default.fileExists(atPath: await responderKeys.authorizedKeysURL.path)
        XCTAssertFalse(aAuthExists, "Initiator should not have written authorized_keys")
        XCTAssertFalse(bAuthExists, "Responder should not have written authorized_keys")
    }

    func testInitiatorRejectsAfterSeeingCode_responderRollsBack() async throws {
        try await responder.start()
        try await initiator.start()
        try await initiator.initiate()

        try await waitUntil(seconds: 2) {
            if case .receivedPairRequest = await self.responder.state { return true }
            return false
        }
        try await responder.acceptPendingRequest()

        try await waitUntil(seconds: 2) {
            if case .receivedPairAccept = await self.initiator.state { return true }
            return false
        }

        // Initiator changes their mind after seeing code.
        try await initiator.reject(reason: "code-mismatch")

        try await waitUntil(seconds: 2) {
            if case .rejected = await self.initiator.state,
               case .rejected = await self.responder.state { return true }
            return false
        }

        // Responder hadn't installed initiator's key (only happens on pairConfirm),
        // so authorized_keys should still be absent on B.
        let bAuthExists = FileManager.default.fileExists(atPath: await responderKeys.authorizedKeysURL.path)
        XCTAssertFalse(bAuthExists,
            "Responder must NOT have installed initiator's key — pairConfirm never arrived")
    }

    // MARK: - Invalid action surfaces error

    func testInitiate_whileAlreadyInitiated_throws() async throws {
        try await initiator.start()
        try await initiator.initiate()
        do {
            try await initiator.initiate()
            XCTFail("Expected invalidStateForAction")
        } catch let PairingManager.PairingError.invalidStateForAction(current, action) {
            XCTAssertEqual(action, "initiate")
            XCTAssertTrue(current.contains("sentPairRequest"), "Got: \(current)")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func testConfirm_whenNoAcceptReceived_throws() async {
        try? await initiator.start()
        do {
            try await initiator.confirmCode()
            XCTFail("Expected invalidStateForAction")
        } catch let PairingManager.PairingError.invalidStateForAction(_, action) {
            XCTAssertEqual(action, "confirmCode")
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    // MARK: - Helpers

    private func waitUntil(
        seconds: TimeInterval,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }
        XCTFail("Condition not met within \(seconds)s")
    }
}
