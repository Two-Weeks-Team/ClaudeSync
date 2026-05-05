import XCTest
@testable import ClaudeSync

/// All tests run against a temporary directory injected as the home dir, so
/// they cannot touch the developer's real `~/.ssh/authorized_keys`.
final class SSHKeyManagerTests: XCTestCase {
    var tempHome: URL!
    var manager: SSHKeyManager!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHKeyManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        manager = SSHKeyManager(homeDirectoryURL: tempHome, machineLabel: "TestMac")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - Generation

    func testEnsureKeyPair_createsBothKeyFiles_withCorrectPermissions() async throws {
        try await manager.ensureKeyPair()

        let priv = await manager.privateKeyURL.path
        let pub  = await manager.publicKeyURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: priv))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pub))

        let attrs = try FileManager.default.attributesOfItem(atPath: priv)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600, "Private key must be 0600")
    }

    func testEnsureKeyPair_isIdempotent() async throws {
        try await manager.ensureKeyPair()
        let firstPriv = try Data(contentsOf: await manager.privateKeyURL)

        try await manager.ensureKeyPair()
        let secondPriv = try Data(contentsOf: await manager.privateKeyURL)

        XCTAssertEqual(firstPriv, secondPriv,
            "Calling ensureKeyPair twice must not regenerate the key")
    }

    func testEnsureKeyPair_reEnforcesPermissions_onExistingKey() async throws {
        try await manager.ensureKeyPair()
        // Tamper: loosen permissions
        let priv = await manager.privateKeyURL.path
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: priv
        )

        try await manager.ensureKeyPair()  // second call should re-enforce 0600

        let attrs = try FileManager.default.attributesOfItem(atPath: priv)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600)
    }

    func testEnsureKeyPair_missingTool_throws() async {
        let bad = SSHKeyManager(
            homeDirectoryURL: tempHome,
            sshKeygenPath: "/no/such/ssh-keygen",
            machineLabel: "TestMac"
        )
        do {
            try await bad.ensureKeyPair()
            XCTFail("Expected toolMissing error")
        } catch SSHKeyManager.KeyError.toolMissing(let path) {
            XCTAssertEqual(path, "/no/such/ssh-keygen")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Read

    func testReadPublicKey_returnsTrimmedSshEd25519Line() async throws {
        try await manager.ensureKeyPair()
        let line = try await manager.readPublicKey()
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 "), "Got: \(line)")
        XCTAssertFalse(line.hasSuffix("\n"))
        XCTAssertTrue(line.contains("claudesync@TestMac"))
    }

    func testReadPublicKeyBytes_returnsExactly32Bytes() async throws {
        try await manager.ensureKeyPair()
        let raw = try await manager.readPublicKeyBytes()
        XCTAssertEqual(raw.count, 32, "Ed25519 raw public key is exactly 32 bytes")
    }

    func testPublicKeyFingerprint_hasOpenSSHFormat() async throws {
        try await manager.ensureKeyPair()
        let fp = try await manager.publicKeyFingerprint()
        XCTAssertTrue(fp.hasPrefix("SHA256:"), "Got: \(fp)")
        XCTAssertFalse(fp.contains("="), "OpenSSH strips '=' padding")
        // base64 portion should be 43 characters (SHA-256 → 32 bytes → ceil(32*4/3) = 44, minus 1 padding char)
        let body = String(fp.dropFirst("SHA256:".count))
        XCTAssertEqual(body.count, 43)
    }

    // MARK: - authorized_keys management

    func testInstallPeerKey_appendsRestrictedEntry_withCorrectPermissions() async throws {
        let peerKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx claudesync@PeerMac"
        try await manager.installPeerKey(peerKey)

        let auth = await manager.authorizedKeysURL
        let contents = try String(contentsOf: auth, encoding: .utf8)
        XCTAssertTrue(contents.contains("restrict,command="))
        XCTAssertTrue(contents.contains("--server"))
        XCTAssertTrue(contents.contains("claudesync@PeerMac"))

        let attrs = try FileManager.default.attributesOfItem(atPath: auth.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600)
    }

    func testInstallPeerKey_thenRemove_roundtripsCleanly() async throws {
        let peerA = "ssh-ed25519 AAAAA1 claudesync@MacAir"
        let peerB = "ssh-ed25519 AAAAA2 claudesync@MacPro"
        try await manager.installPeerKey(peerA)
        try await manager.installPeerKey(peerB)

        // Sanity: both present
        let auth = await manager.authorizedKeysURL
        let before = try String(contentsOf: auth, encoding: .utf8)
        XCTAssertTrue(before.contains("claudesync@MacAir"))
        XCTAssertTrue(before.contains("claudesync@MacPro"))

        // Remove only MacAir
        try await manager.removePeerKey(matchingComment: "claudesync@MacAir")
        let after = try String(contentsOf: auth, encoding: .utf8)
        XCTAssertFalse(after.contains("claudesync@MacAir"))
        XCTAssertTrue(after.contains("claudesync@MacPro"),
            "Remove must be selective — other entries stay")
    }

    func testInstallPeerKey_doesNotClobberPreexistingEntries() async throws {
        // Simulate a user who already has authorized_keys with their own line.
        let auth = await manager.authorizedKeysURL
        let sshDir = await manager.sshDirectoryURL
        try FileManager.default.createDirectory(at: sshDir,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let preexisting = "ssh-ed25519 AAAAUserKey kim@laptop\n"
        try preexisting.write(to: auth, atomically: true, encoding: .utf8)

        try await manager.installPeerKey("ssh-ed25519 AAAAPeer claudesync@PeerMac")

        let final = try String(contentsOf: auth, encoding: .utf8)
        XCTAssertTrue(final.contains("kim@laptop"), "User's existing entry must survive")
        XCTAssertTrue(final.contains("claudesync@PeerMac"))
    }

    func testRemovePeerKey_whenAuthorizedKeysMissing_isNoop() async throws {
        try await manager.removePeerKey(matchingComment: "claudesync@anything")
        // No throw, no file created
        let path = await manager.authorizedKeysURL.path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Integrity

    func testVerifyKeyIntegrity_missing_returnsMissing() async throws {
        let status = try await manager.verifyKeyIntegrity()
        XCTAssertEqual(status, .missing)
    }

    func testVerifyKeyIntegrity_valid_after_ensure() async throws {
        try await manager.ensureKeyPair()
        let status = try await manager.verifyKeyIntegrity()
        XCTAssertEqual(status, .valid)
    }

    func testVerifyKeyIntegrity_loosePermissions_returnsIncorrect() async throws {
        try await manager.ensureKeyPair()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: await manager.privateKeyURL.path
        )
        let status = try await manager.verifyKeyIntegrity()
        XCTAssertEqual(status, .permissionsIncorrect(current: 0o644))
    }

    // MARK: - Integration with PairingCodeGenerator

    func testPairingCodeFromGeneratedKey_isStable() async throws {
        try await manager.ensureKeyPair()
        let myKeyBytes = try await manager.readPublicKeyBytes()
        let peerKeyBytes = Data(repeating: 0xAB, count: 32)

        let code1 = PairingCodeGenerator.generateCode(
            initiatorPublicKey: myKeyBytes, responderPublicKey: peerKeyBytes
        )
        let code2 = PairingCodeGenerator.generateCode(
            initiatorPublicKey: myKeyBytes, responderPublicKey: peerKeyBytes
        )
        XCTAssertEqual(code1, code2)
        XCTAssertEqual(code1.count, 6)
    }
}
