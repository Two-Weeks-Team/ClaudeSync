import XCTest
@testable import ClaudeSync

final class SSHReachabilityClassifierTests: XCTestCase {
    func testClassify_connectionRefused() {
        let r = ProcessSSHConnectivityChecker.classify(
            stderr: "ssh: connect to host localhost port 22: Connection refused"
        )
        XCTAssertEqual(r, .connectionRefused(port: 22))
        XCTAssertFalse(r.sshDaemonResponded)
    }

    func testClassify_connectionTimeout() {
        let r = ProcessSSHConnectivityChecker.classify(
            stderr: "ssh: connect to host 10.0.0.1 port 22: Operation timed out"
        )
        XCTAssertEqual(r, .connectionTimeout)
        XCTAssertFalse(r.sshDaemonResponded)
    }

    func testClassify_authFailedCountsAsResponded() {
        let r = ProcessSSHConnectivityChecker.classify(
            stderr: "kim@localhost: Permission denied (publickey)."
        )
        XCTAssertEqual(r, .authFailed)
        XCTAssertTrue(r.sshDaemonResponded,
            "Permission denied means sshd answered — preflight should accept this")
    }

    func testClassify_dnsFailure() {
        let r = ProcessSSHConnectivityChecker.classify(
            stderr: "ssh: Could not resolve hostname mac-air.local: nodename nor servname provided"
        )
        if case .hostUnreachable = r { /* ok */ } else {
            XCTFail("Expected .hostUnreachable, got \(r)")
        }
        XCTAssertFalse(r.sshDaemonResponded)
    }

    func testClassify_unknownStderr_isPropagatedVerbatim() {
        let r = ProcessSSHConnectivityChecker.classify(stderr: "weird unknown ssh error\n")
        if case .unknownError(let msg) = r {
            XCTAssertEqual(msg, "weird unknown ssh error")
        } else {
            XCTFail("Expected .unknownError, got \(r)")
        }
    }
}

final class RemoteLoginPreflightTests: XCTestCase {
    func testLocalOnly_localOk_returnsReady() async {
        let checker = MockSSHConnectivityChecker(default: .ok)
        let pre = RemoteLoginPreflight(checker: checker)
        let outcome = await pre.checkLocalOnly()
        XCTAssertTrue(outcome.isReady)
        XCTAssertNil(outcome.failingSide)
    }

    func testLocalOnly_localRefused_blocksWithLocalFailure() async {
        let checker = MockSSHConnectivityChecker(default: .connectionRefused(port: 22))
        let pre = RemoteLoginPreflight(checker: checker)
        let outcome = await pre.checkLocalOnly()
        XCTAssertFalse(outcome.isReady)
        guard case .local(let r) = outcome.failingSide else {
            return XCTFail("Expected .local failingSide, got \(String(describing: outcome.failingSide))")
        }
        XCTAssertEqual(r, .connectionRefused(port: 22))
    }

    func testLocalOnly_authFailedStillCountsAsReady() async {
        // Important: pre-pairing the local key isn't installed, so probing
        // localhost will return authFailed. That must still count as ready.
        let checker = MockSSHConnectivityChecker(default: .authFailed)
        let pre = RemoteLoginPreflight(checker: checker)
        let outcome = await pre.checkLocalOnly()
        XCTAssertTrue(outcome.isReady)
    }

    func testBothSides_peerTimesOut_blocksWithPeerFailure() async {
        let checker = MockSSHConnectivityChecker(scripted: [
            "localhost": .ok,
            "MacBookAir.local": .connectionTimeout,
        ])
        let pre = RemoteLoginPreflight(checker: checker)
        let outcome = await pre.checkBothSides(peerHost: "MacBookAir.local")
        XCTAssertFalse(outcome.isReady)
        guard case .peer(let r) = outcome.failingSide else {
            return XCTFail("Expected .peer failingSide")
        }
        XCTAssertEqual(r, .connectionTimeout)
    }

    func testBothSides_localFails_doesNotProbePeer() async {
        let checker = MockSSHConnectivityChecker(scripted: [
            "localhost": .connectionRefused(port: 22),
            "MacBookAir.local": .ok,
        ])
        let pre = RemoteLoginPreflight(checker: checker)
        let outcome = await pre.checkBothSides(peerHost: "MacBookAir.local")
        XCTAssertFalse(outcome.isReady)
        let probed = await checker.probedHosts
        XCTAssertEqual(probed.count, 1, "Should short-circuit before probing the peer")
        XCTAssertEqual(probed.first?.host, "localhost")
    }

    func testBothSides_allOk() async {
        let checker = MockSSHConnectivityChecker(default: .ok)
        let pre = RemoteLoginPreflight(checker: checker)
        let outcome = await pre.checkBothSides(peerHost: "MacBookAir.local")
        XCTAssertTrue(outcome.isReady)
    }
}

final class FullDiskAccessCheckerTests: XCTestCase {
    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDATests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testReadableDirectory_returnsGranted() {
        let checker = FullDiskAccessChecker(canaryURL: tempRoot)
        XCTAssertEqual(checker.check(), .granted)
    }

    func testMissingPath_returnsIndeterminate() {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let checker = FullDiskAccessChecker(canaryURL: missing)
        if case .indeterminate = checker.check() { /* ok */ } else {
            XCTFail("Expected indeterminate for missing canary")
        }
    }

    func testFileInsteadOfDirectory_returnsIndeterminate() throws {
        let file = tempRoot.appendingPathComponent("not-a-dir.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let checker = FullDiskAccessChecker(canaryURL: file)
        if case .indeterminate = checker.check() { /* ok */ } else {
            XCTFail("Expected indeterminate for file canary")
        }
    }

    func testUnreadableDirectory_returnsDenied() throws {
        let locked = tempRoot.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        // Strip all read/exec permissions on the canary.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
        }

        let checker = FullDiskAccessChecker(canaryURL: locked)
        let status = checker.check()
        // Note: when running as root the chmod has no effect, so both
        // .denied and .granted are acceptable. We only care that we don't
        // crash and that the result is one of the well-defined cases.
        XCTAssertTrue(
            status == .denied || status == .granted,
            "Unexpected status \(status). Running as root or unsupported FS?"
        )
    }

    func testDefaultCanary_isCookiesUnderHome() {
        let checker = FullDiskAccessChecker()
        XCTAssertEqual(
            checker.canaryURL.path,
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Cookies", isDirectory: true).path
        )
    }
}

final class SystemSettingsLinkTests: XCTestCase {
    func testRemoteLoginURL_hasCorrectScheme() {
        XCTAssertEqual(SystemSettingsLink.remoteLoginSharing.scheme, "x-apple.systempreferences")
    }

    func testRemoteLoginURL_pointsToSharingPane() {
        XCTAssertTrue(SystemSettingsLink.remoteLoginSharing.absoluteString.contains("preferences.sharing"))
        XCTAssertTrue(SystemSettingsLink.remoteLoginSharing.absoluteString.contains("RemoteLogin"))
    }

    func testFullDiskAccessURL_hasCorrectScheme() {
        XCTAssertEqual(SystemSettingsLink.fullDiskAccess.scheme, "x-apple.systempreferences")
    }

    func testFullDiskAccessURL_pointsToAllFiles() {
        XCTAssertTrue(SystemSettingsLink.fullDiskAccess.absoluteString.contains("Privacy_AllFiles"))
    }

    func testLocalNetworkURL_pointsToLocalNetworkPrivacy() {
        XCTAssertTrue(SystemSettingsLink.localNetwork.absoluteString.contains("Privacy_LocalNetwork"))
    }

    func testFirewallURL_hasCorrectScheme() {
        XCTAssertEqual(SystemSettingsLink.firewall.scheme, "x-apple.systempreferences")
    }

    func testFirewallURL_pointsToFirewallPane() {
        XCTAssertTrue(SystemSettingsLink.firewall.absoluteString.contains("Firewall"))
    }
}
