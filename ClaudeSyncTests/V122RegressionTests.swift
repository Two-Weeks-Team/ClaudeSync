import XCTest
@testable import ClaudeSync

/// v1.2.2: control-channel keepalive during pairing.
///
/// Symptom this guards against: the visual 6-digit confirmation step is
/// user-paced, and a quiet established connection was getting reaped (NAT
/// idle timeout / App Nap throttling the menu-bar app), surfacing as
/// "Pairing failed: send pairAccept failed: closed" or an indefinite hang
/// on "Step 3 of 3". The fix: PairingManager sends a heartbeat every
/// `heartbeatInterval` for the lifetime of the handshake, and turns a dead
/// transport into a prompt `.failed` instead of a silent stall.
final class V122RegressionTests: XCTestCase {

    private var home: URL!
    private var keys: SSHKeyManager!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v122-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        keys = SSHKeyManager(homeDirectoryURL: home, machineLabel: "MacTest")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeManager(channel: PeerChannel,
                             heartbeatInterval: Duration) -> PairingManager {
        PairingManager(
            channel: channel, sshKeys: keys,
            identity: .init(machineId: UUID(), hostname: "MacTest", username: "kim", sshPort: 22),
            heartbeatInterval: heartbeatInterval
        )
    }

    private func waitUntil(seconds: TimeInterval,
                           _ cond: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(seconds)s")
    }

    // MARK: - heartbeat is emitted while a handshake is live

    func testHeartbeatsAreSentAfterStart() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()
        _ = b   // partner end, just keeps the pair connected
        let mgr = makeManager(channel: a, heartbeatInterval: .milliseconds(40))
        try await mgr.start()

        try await waitUntil(seconds: 2) {
            a.sentMessages.contains {
                if case .heartbeat = $0 { return true }; return false
            }
        }
        await mgr.cancel()
    }

    // MARK: - heartbeat stops once a terminal state is reached

    func testHeartbeatStopsAfterTerminalState() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()
        _ = b
        let mgr = makeManager(channel: a, heartbeatInterval: .milliseconds(40))
        try await mgr.start()
        // Drive to a terminal state.
        try await mgr.reject(reason: "test")
        let state = await mgr.state
        guard case .rejected = state else { return XCTFail("expected .rejected, got \(state)") }

        // Let any in-flight heartbeat land, snapshot, then ensure it stays put.
        try await Task.sleep(nanoseconds: 120_000_000)
        let countAfterTerminal = a.sentMessages.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(a.sentMessages.count, countAfterTerminal,
            "no further heartbeats should be sent after a terminal state")
        await mgr.cancel()
    }

    // MARK: - a dead transport mid-handshake becomes a prompt .failed

    func testChannelCloseMidHandshakeSurfacesFailed() async throws {
        let (a, b) = LoopbackPeerChannel.makePair()
        let mgr = makeManager(channel: a, heartbeatInterval: .milliseconds(40))
        try await mgr.start()
        try await mgr.initiate()
        let mid = await mgr.state
        guard case .sentPairRequest = mid else { return XCTFail("expected .sentPairRequest, got \(mid)") }

        // Peer vanishes — close both ends of the loopback.
        await b.close()
        await a.close()

        try await waitUntil(seconds: 2) {
            if case .failed = await mgr.state { return true }; return false
        }
        await mgr.cancel()
    }

    // MARK: - the configured production interval is sane

    func testProductionHeartbeatIntervalIsModest() {
        XCTAssertEqual(PairingManager.heartbeatInterval, .seconds(5))
    }
}
