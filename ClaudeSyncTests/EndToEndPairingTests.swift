import XCTest
@testable import ClaudeSync

/// End-to-end demonstration of the full Phase 2+3 pairing pipeline.
///
/// Two completely independent stacks (each with its own SSHKeyManager rooted
/// at a separate temporary home directory) negotiate pairing through a
/// single `LoopbackPeerChannel` pair. At the end both authorized_keys files
/// contain the peer's restricted entry, both sides agree on a 6-digit code,
/// and `PairingManager.PairedPeer` records mirror each other.
final class EndToEndPairingTests: XCTestCase {

    func testFullPairingHandshake_endToEnd() async throws {
        // ── Two isolated environments (think Mac A vs Mac B) ─────────────
        let homeA = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2E-A-\(UUID().uuidString)", isDirectory: true)
        let homeB = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2E-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: homeA)
            try? FileManager.default.removeItem(at: homeB)
        }

        let keysA = SSHKeyManager(homeDirectoryURL: homeA, machineLabel: "MacBookPro")
        let keysB = SSHKeyManager(homeDirectoryURL: homeB, machineLabel: "MacBookAir")

        let (channelA, channelB) = LoopbackPeerChannel.makePair()

        let identityA = PairingManager.LocalIdentity(
            machineId: UUID(), hostname: "MacBookPro", username: "kim", sshPort: 22
        )
        let identityB = PairingManager.LocalIdentity(
            machineId: UUID(), hostname: "MacBookAir", username: "kim", sshPort: 22
        )

        let macA = PairingManager(channel: channelA, sshKeys: keysA, identity: identityA)
        let macB = PairingManager(channel: channelB, sshKeys: keysB, identity: identityB)

        // ── 1. Both sides start listening ────────────────────────────────
        try await macA.start()
        try await macB.start()

        // ── 2. A sends pairRequest ───────────────────────────────────────
        try await macA.initiate()

        // ── 3. Wait for B to surface the pending request to its UI ───────
        try await waitFor(seconds: 2) {
            if case .receivedPairRequest = await macB.state { return true }
            return false
        }
        guard case .receivedPairRequest(_, let codeOnB) = await macB.state else {
            return XCTFail()
        }

        // ── 4. B's user accepts → B sends pairAccept ────────────────────
        try await macB.acceptPendingRequest()

        // ── 5. A receives pairAccept, computes the same code ────────────
        try await waitFor(seconds: 2) {
            if case .receivedPairAccept = await macA.state { return true }
            return false
        }
        guard case .receivedPairAccept(_, let codeOnA) = await macA.state else {
            return XCTFail()
        }

        // ── 6. ★ Visual confirmation codes match on both screens ────────
        XCTAssertEqual(codeOnA, codeOnB, "Both sides must compute the SAME 6-digit code")
        XCTAssertEqual(codeOnA.count, 6)
        XCTAssertTrue(codeOnA.allSatisfy { $0.isNumber })

        // ── 7. A confirms, sends pairConfirm ─────────────────────────────
        try await macA.confirmCode()

        // ── 8. Both terminate in .completed ──────────────────────────────
        try await waitFor(seconds: 2) {
            if case .completed = await macA.state, case .completed = await macB.state {
                return true
            }
            return false
        }

        // ── 9. authorized_keys contains the peer key on each side ───────
        let authA = try String(contentsOf: await keysA.authorizedKeysURL, encoding: .utf8)
        let authB = try String(contentsOf: await keysB.authorizedKeysURL, encoding: .utf8)

        XCTAssertTrue(authA.contains("claudesync@MacBookAir"),
            "Mac A's authorized_keys must contain Mac B's key")
        let wrapperA = await keysA.rsyncWrapperURL.path
        XCTAssertTrue(authA.contains("restrict,command=") && authA.contains(wrapperA),
            "Installed entry must carry the rsync-only restriction (wrapper path)")

        XCTAssertTrue(authB.contains("claudesync@MacBookPro"),
            "Mac B's authorized_keys must contain Mac A's key")
        let wrapperB = await keysB.rsyncWrapperURL.path
        XCTAssertTrue(authB.contains("restrict,command=") && authB.contains(wrapperB),
            "Installed entry must carry the rsync-only restriction (wrapper path)")

        // ── 10. PairedPeer records are mutually consistent ──────────────
        guard case .completed(let peerOnA) = await macA.state,
              case .completed(let peerOnB) = await macB.state else {
            return XCTFail("Both sides should be .completed")
        }
        XCTAssertEqual(peerOnA.machineId, identityB.machineId)
        XCTAssertEqual(peerOnB.machineId, identityA.machineId)
        XCTAssertEqual(peerOnA.hostname, identityB.hostname)
        XCTAssertEqual(peerOnB.hostname, identityA.hostname)
    }

    // MARK: - Helpers

    private func waitFor(
        seconds: TimeInterval,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Condition not met within \(seconds)s")
    }
}
