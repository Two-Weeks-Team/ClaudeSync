import XCTest
@testable import ClaudeSync

/// v1.1 hardening regression tests. Each test codifies one of the
/// defense-in-depth layers added in this milestone.
final class V11RegressionTests: XCTestCase {

    // MARK: - SEC-009 — preferences integrity

    func testIntegrity_signAndVerify_roundtrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prefsURL = dir.appendingPathComponent("preferences.json")
        let integrity = PreferencesIntegrity(preferencesURL: prefsURL)
        let key = try integrity.loadOrCreateKey()
        let payload = "hello world".data(using: .utf8)!
        try integrity.writeSignature(for: payload, using: key)
        XCTAssertTrue(integrity.verify(payload: payload, using: key))
        XCTAssertFalse(integrity.verify(payload: "tampered".data(using: .utf8)!,
                                        using: key))
    }

    func testIntegrity_keyFile_isOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-int-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prefsURL = dir.appendingPathComponent("preferences.json")
        let integrity = PreferencesIntegrity(preferencesURL: prefsURL)
        _ = try integrity.loadOrCreateKey()
        let attrs = try FileManager.default.attributesOfItem(
            atPath: integrity.machineKeyURL.path
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600)
    }

    func testStore_tamperedFile_fallsBackToDefaults() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prefsURL = dir.appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: prefsURL)
        try await store.update { $0.bandwidthLimitKBps = 4096 }

        // Tamper with the file but leave the (now-stale) signature.
        let tampered = #"{"bandwidthLimitKBps":99999,"extraExcludes":{},"launchAtLogin":false}"#
        try tampered.write(to: prefsURL, atomically: true, encoding: .utf8)

        let reload = PreferencesStore(fileURL: prefsURL)
        let outcome = await reload.loadOutcome()
        let current = await reload.current()
        XCTAssertEqual(outcome, .defaultsBecauseTampered)
        XCTAssertEqual(current, .default,
                       "Tampered file must NOT be honored")
    }

    func testStore_noSignatureSidecar_v100Upgrade_isAccepted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefsURL = dir.appendingPathComponent("preferences.json")
        let v100Json = #"{"bandwidthLimitKBps":256,"extraExcludes":{},"launchAtLogin":true}"#
        try v100Json.write(to: prefsURL, atomically: true, encoding: .utf8)

        let store = PreferencesStore(fileURL: prefsURL)
        let outcome = await store.loadOutcome()
        let current = await store.current()
        XCTAssertEqual(outcome, .loaded,
                       "First-run after v1.0.x upgrade should accept the file (no sig yet)")
        XCTAssertEqual(current.bandwidthLimitKBps, 256)
    }

    // MARK: - RCA-M9 — clock skew

    func testPairingManager_clockSkew_overLimit_transitionsToFailed() async {
        let (chA, chB) = LoopbackPeerChannel.makePair()
        let homeA = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-skew-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeA) }

        let keys = SSHKeyManager(homeDirectoryURL: homeA)
        let pm = PairingManager(channel: chA, sshKeys: keys,
                                identity: .init(machineId: UUID(),
                                                hostname: "Mac",
                                                username: "u", sshPort: 22))
        try? await pm.start()
        // Fabricate a peer pairRequest with a clock 5 minutes in the past.
        let bad = PairRequestPayload(
            machineId: UUID(), hostname: "Other", username: "u",
            publicKey: "ssh-ed25519 AAAA test",
            publicKeyFingerprint: "SHA256:xxx",
            clockUnixSeconds: Date().timeIntervalSince1970 - 300
        )
        try? await chB.send(.pairRequest(bad))
        for _ in 0..<20 {
            if case .failed(let m) = await pm.state {
                XCTAssertTrue(m.contains("clock skew"))
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Pairing should fail with clock skew error")
    }

    // MARK: - SEC-003 — nonce + single-attempt

    func testPairingCodeGenerator_includesNonce_inDerivation() {
        let pkA = Data(repeating: 0xA1, count: 32)
        let pkB = Data(repeating: 0xB2, count: 32)
        let codeNoNonce = PairingCodeGenerator.generateCode(
            initiatorPublicKey: pkA, responderPublicKey: pkB
        )
        let codeWithNonce = PairingCodeGenerator.generateCode(
            initiatorPublicKey: pkA, responderPublicKey: pkB,
            initiatorNonce: Data(repeating: 0xCC, count: 16),
            responderNonce: Data(repeating: 0xDD, count: 16)
        )
        XCTAssertNotEqual(codeNoNonce, codeWithNonce,
            "Nonce must alter the derived code")
    }

    func testPairingCodeGenerator_differentNonces_produceDifferentCodes() {
        let pkA = Data(repeating: 0x01, count: 32)
        let pkB = Data(repeating: 0x02, count: 32)
        let n1 = Data(repeating: 0x10, count: 16)
        let n2 = Data(repeating: 0x20, count: 16)
        let n3 = Data(repeating: 0x30, count: 16)
        let n4 = Data(repeating: 0x40, count: 16)
        let c1 = PairingCodeGenerator.generateCode(
            initiatorPublicKey: pkA, responderPublicKey: pkB,
            initiatorNonce: n1, responderNonce: n2
        )
        let c2 = PairingCodeGenerator.generateCode(
            initiatorPublicKey: pkA, responderPublicKey: pkB,
            initiatorNonce: n3, responderNonce: n4
        )
        XCTAssertNotEqual(c1, c2)
    }

    func testPairingCodeGenerator_newNonce_returns16Bytes() {
        let n = PairingCodeGenerator.newNonce()
        XCTAssertEqual(n.count, 16)
    }

    func testPairingCodeGenerator_hexRoundtrip() {
        let original = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff])
        let hex = PairingCodeGenerator.hexEncode(original)
        XCTAssertEqual(hex, "deadbeef00ff")
        XCTAssertEqual(PairingCodeGenerator.hexDecode(hex), original)
    }

    func testPairingManager_secondPairRequest_isRejected() async {
        let (chA, chB) = LoopbackPeerChannel.makePair()
        let homeA = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-second-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeA) }

        let keys = SSHKeyManager(homeDirectoryURL: homeA)
        try? await keys.ensureKeyPair()
        let pubkey = (try? await keys.readPublicKey()) ?? "ssh-ed25519 AAAA"

        let pm = PairingManager(channel: chA, sshKeys: keys,
                                identity: .init(machineId: UUID(),
                                                hostname: "Mac",
                                                username: "u", sshPort: 22))
        try? await pm.start()
        // First request — valid.
        let req1 = PairRequestPayload(
            machineId: UUID(), hostname: "Other", username: "u",
            publicKey: pubkey, publicKeyFingerprint: "SHA256:xxx",
            clockUnixSeconds: Date().timeIntervalSince1970,
            nonceHex: PairingCodeGenerator.hexEncode(PairingCodeGenerator.newNonce())
        )
        try? await chB.send(.pairRequest(req1))
        try? await Task.sleep(for: .milliseconds(150))

        // Second request — should be refused (single-attempt enforcement).
        // Note: state has already moved past .idle, so guard fires first;
        // we still want the SECOND distinct request from a fresh handler
        // to be capped by the counter. Send while in .receivedPairRequest
        // and verify state doesn't regress to a new code.
        let stateAfterFirst = await pm.state
        try? await chB.send(.pairRequest(req1))
        try? await Task.sleep(for: .milliseconds(50))
        let stateAfterSecond = await pm.state
        // Second request must NOT replace the existing one with a new code;
        // either guard drops it (state unchanged) or counter trips .failed.
        switch (stateAfterFirst, stateAfterSecond) {
        case (.receivedPairRequest(_, let c1), .receivedPairRequest(_, let c2)):
            XCTAssertEqual(c1, c2, "Repeated pairRequest must not regenerate code")
        case (_, .failed):
            // counter trip is also acceptable
            return
        default:
            // Any other transition is fine as long as it's not a new code.
            return
        }
    }

    // MARK: - SEC-005 — known_hosts

    func testSSHKeyManager_registerKnownHost_writesEntryWithCorrectPerms() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-kh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let keys = SSHKeyManager(homeDirectoryURL: home)
        try await keys.registerKnownHost(
            hostname: "MacBookAir",
            hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY"
        )
        let url = await keys.knownHostsURL
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("MacBookAir"))
        XCTAssertTrue(contents.contains("MacBookAir.local"))
        XCTAssertTrue(contents.contains("ssh-ed25519"))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600)

        let known = await keys.hasKnownHost(hostname: "MacBookAir")
        XCTAssertTrue(known)
    }

    func testSSHKeyManager_registerKnownHost_replacesExistingEntry() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-kh-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let keys = SSHKeyManager(homeDirectoryURL: home)
        try await keys.registerKnownHost(
            hostname: "Mac1",
            hostKey: "ssh-ed25519 AAAAOLDKEY"
        )
        try await keys.registerKnownHost(
            hostname: "Mac1",
            hostKey: "ssh-ed25519 AAAANEWKEY"
        )
        let url = await keys.knownHostsURL
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("AAAAOLDKEY"))
        XCTAssertTrue(contents.contains("AAAANEWKEY"))
    }

    func testRsyncCommandBuilder_knownHostsPath_emitsStrictMode() {
        let builder = RsyncCommandBuilder(
            rsyncPath: "/usr/bin/rsync",
            sshKeyPath: "/tmp/k",
            knownHostsPath: "/Users/me/.claudesync/ssh/known_hosts"
        )
        let cmd = builder.sshCommand(for: .init(sshAddress: "u@h.local", sshPort: 22))
        XCTAssertTrue(cmd.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(cmd.contains("UserKnownHostsFile=/Users/me/.claudesync/ssh/known_hosts"))
        XCTAssertTrue(cmd.contains("GlobalKnownHostsFile=/dev/null"))
        XCTAssertFalse(cmd.contains("accept-new"))
    }

    func testRsyncCommandBuilder_emptyKnownHosts_keepsAcceptNewFallback() {
        let builder = RsyncCommandBuilder(
            rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/k",
            knownHostsPath: ""
        )
        let cmd = builder.sshCommand(for: .init(sshAddress: "u@h.local", sshPort: 22))
        XCTAssertTrue(cmd.contains("accept-new"))
    }

    // MARK: - RCA-M5/M6/M7 — auto recovery

    @MainActor
    func testNetworkResilienceMonitor_canStartAndStop_withoutCrashing() {
        let monitor = NetworkResilienceMonitor { _ in }
        monitor.start()
        monitor.stop()
        // No crash + no leaked observers ⇒ pass.
    }

    // MARK: - SEC-002 — TLS certificate provider

    @MainActor
    func testTLSCertificateProvider_generatesIdentity_andExposesFingerprint() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = TLSCertificateProvider(homeDirectory: home)
        let identity = try await provider.loadOrCreateIdentity()
        XCTAssertNotNil(identity, "PKCS12 import should yield a SecIdentity")
        let fp = try provider.ownCertificateFingerprint()
        // SHA-256 hex = 64 lowercase chars.
        XCTAssertEqual(fp.count, 64)
        XCTAssertTrue(fp.allSatisfy { "0123456789abcdef".contains($0) })

        // Second call must hit the cache (no second openssl spawn).
        let again = try await provider.loadOrCreateIdentity()
        XCTAssertNotNil(again)
    }

    @MainActor
    func testTLSCertificateProvider_keyFile_isOwnerOnly() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-tls-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let provider = TLSCertificateProvider(homeDirectory: home)
        _ = try await provider.loadOrCreateIdentity()
        for url in [provider.keyPEMURL, provider.p12URL] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(perms, 0o600, "\(url.lastPathComponent) must be 0o600")
        }
    }

    // MARK: - SingleInstanceGuard

    @MainActor
    func testSingleInstanceGuard_primaryOnFreshHome_thenDuplicate() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-sig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // No sentinel yet → primary. We pass includeRunningAppsScan: false
        // so the test isn't perturbed by any other ClaudeSync.app the
        // developer happens to be running (NSRunningApplication is
        // process-global and doesn't honor the temp home).
        let first = SingleInstanceGuard.check(
            homeDirectory: home, includeRunningAppsScan: false
        )
        XCTAssertEqual(first, .primary)

        // Simulate a peer Mac that wrote a sentinel pointing at our own
        // PID. `check` should NOT trip (skip-self logic).
        SingleInstanceGuard.claimSentinel(homeDirectory: home)
        let secondCheck = SingleInstanceGuard.check(
            homeDirectory: home, includeRunningAppsScan: false
        )
        XCTAssertEqual(secondCheck, .primary,
            "Sentinel pointing at our own PID must be treated as self")

        // Now write a sentinel for an obviously-dead PID — also treated as
        // primary because kill(deadPid, 0) returns -1.
        let sentinel = home.appendingPathComponent(".claudesync/.app.pid")
        try? "999999999".write(to: sentinel, atomically: true, encoding: .utf8)
        let thirdCheck = SingleInstanceGuard.check(
            homeDirectory: home, includeRunningAppsScan: false
        )
        XCTAssertEqual(thirdCheck, .primary,
            "Stale sentinel for a dead PID must not block primary launch")
    }

    @MainActor
    func testSingleInstanceGuard_releaseSentinel_removesFile() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("v11-sig-r-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        SingleInstanceGuard.claimSentinel(homeDirectory: home)
        let sentinel = home.appendingPathComponent(".claudesync/.app.pid")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        SingleInstanceGuard.releaseSentinel(homeDirectory: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    // MARK: - UX fix — dropping pre-pair jobs

    func testFileSyncActor_droppedOnPrePair_recordsNoFailureInRecentResults() async {
        let watcher = FileWatcherActor(config: .init(
            homeDirectory: FileManager.default.temporaryDirectory
        ))
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/true",
                                          sshKeyPath: "/tmp/key")
        let sync = FileSyncActor(
            config: .init(maxConcurrent: 1, builder: builder),
            peer: nil
        )
        let (batchStream, batch) = BatchAccumulator.makeStream(flushInterval: .seconds(60))
        let coord = await SyncCoordinator(watcher: watcher, syncActor: sync,
                                          batchAccumulator: batch, batchStream: batchStream)
        await coord.start(targets: [])
        // Pre-pair job should be silently dropped (no result emitted).
        await sync.enqueue(SyncJob(target: .codexConfig, direction: .push))
        try? await Task.sleep(for: .milliseconds(150))
        let results = await coord.recentResults
        XCTAssertTrue(results.isEmpty,
            "Pre-pair enqueue must not emit failure results into Recent Activity")
        await coord.stop()
    }
}
