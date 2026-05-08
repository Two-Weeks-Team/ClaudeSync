import XCTest
@testable import ClaudeSync

/// v1.2 regression tests — iCloud Keychain auto-pair.
final class V12RegressionTests: XCTestCase {

    // MARK: - PeerRecord codable round-trip

    func testPeerRecord_codableRoundtrip_preservesAllFields() throws {
        let record = ICloudPairingShare.PeerRecord(
            machineId: UUID(),
            hostname: "MacBookAir",
            username: "kim",
            sshPort: 22,
            publicKeyFingerprint: "SHA256:test-fingerprint",
            sshHostKey: "ssh-ed25519 AAAA test",
            advertisedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(
            ICloudPairingShare.PeerRecord.self, from: data
        )
        XCTAssertEqual(decoded, record)
    }

    // MARK: - ICloudPairingShare publish + lookup round-trip

    /// SecItemAdd with kSecAttrSynchronizable=true requires iCloud
    /// Keychain to be enabled. On the dev Mac this usually works; in
    /// CI it fails. We probe by attempting a publish — if it returns
    /// false, we XCTSkip rather than fail the test (the production
    /// fallback is the visual-code flow, which is exercised by the
    /// existing 214 tests).
    func testPublishAndLookup_roundtripsThroughKeychain() throws {
        let share = ICloudPairingShare(
            service: "com.claudesync.test-\(UUID().uuidString)"
        )
        let myId = UUID()
        let record = ICloudPairingShare.PeerRecord(
            machineId: myId,
            hostname: "TestMac",
            username: "tester",
            sshPort: 22,
            publicKeyFingerprint: "SHA256:abcd",
            sshHostKey: "ssh-ed25519 AAAA"
        )
        let published = share.publish(record)
        if !published {
            throw XCTSkip("iCloud Keychain unavailable in this environment — production path falls back to visual-code flow")
        }
        defer { share.unpublish(machineId: myId) }

        guard let looked = share.lookup(machineId: myId) else {
            return XCTFail("Published record was not findable by lookup()")
        }
        XCTAssertEqual(looked.machineId, record.machineId)
        XCTAssertEqual(looked.publicKeyFingerprint, record.publicKeyFingerprint)
    }

    // MARK: - Lookup of nonexistent machineId returns nil

    func testLookup_unknownMachineId_returnsNil() {
        let share = ICloudPairingShare(
            service: "com.claudesync.test-empty-\(UUID().uuidString)"
        )
        XCTAssertNil(share.lookup(machineId: UUID()))
    }

    // MARK: - Preferences default + backwards compat

    func testPreferences_default_hasAutoPairOn() {
        XCTAssertTrue(Preferences.default.autoPairSameAppleID,
            "v1.2 default: auto-pair via iCloud Keychain is opt-out")
    }

    func testPreferences_decodeV11File_withoutAutoPairField_defaultsToTrue() throws {
        // Older preferences.json from v1.1.x didn't have autoPairSameAppleID.
        let v11Json = """
        {
          "bandwidthLimitKBps": 0,
          "extraExcludes": {},
          "launchAtLogin": false,
          "pairedPeer": null
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Preferences.self, from: v11Json)
        XCTAssertTrue(decoded.autoPairSameAppleID,
            "Missing field must decode to v1.2 default (true)")
    }

    func testPreferences_codableRoundtrip_withAutoPairFalse() throws {
        let p = Preferences(autoPairSameAppleID: false)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(back.autoPairSameAppleID)
    }

    // MARK: - Service name namespacing

    func testServiceName_isNamespaced() {
        XCTAssertEqual(ICloudPairingShare.serviceName,
                       "com.claudesync.pairing-handshake")
    }
}
