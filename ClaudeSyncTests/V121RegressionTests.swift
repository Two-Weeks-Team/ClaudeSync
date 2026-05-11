import XCTest
@testable import ClaudeSync

/// v1.2.1: iCloud Drive file-based pairing share — the entitlement-free
/// fallback for ad-hoc-signed builds where iCloud Keychain refuses
/// (errSecMissingEntitlement).
final class V121RegressionTests: XCTestCase {

    // MARK: - publish + lookup round-trip in a temp "iCloud Drive" home

    /// Use a temp home so we don't pollute the real ~/Library/Mobile
    /// Documents/com.apple.CloudDocs. The share class layers
    /// `<home>/Library/Mobile Documents/com.apple.CloudDocs/<subpath>/`
    /// so building the parent path gives us a writable test directory
    /// AND triggers `isAvailable=true`.
    private func makeShareWithTempHome() throws -> (ICloudDrivePairingShare, URL) {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("v121-icd-\(UUID().uuidString)")
        let cloudParent = tempHome.appendingPathComponent(
            "Library/Mobile Documents/com.apple.CloudDocs"
        )
        try FileManager.default.createDirectory(
            at: cloudParent, withIntermediateDirectories: true
        )
        let share = ICloudDrivePairingShare(
            homeDirectory: tempHome,
            subpath: "ClaudeSync/peers"
        )
        return (share, tempHome)
    }

    func testIsAvailable_trueWhenCloudDocsExists() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(share.isAvailable,
            "isAvailable must report true when CloudDocs parent exists")
    }

    func testIsAvailable_falseWhenCloudDocsMissing() {
        let bogusHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("v121-no-icloud-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: bogusHome, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: bogusHome) }
        let share = ICloudDrivePairingShare(homeDirectory: bogusHome)
        XCTAssertFalse(share.isAvailable,
            "isAvailable must be false when CloudDocs parent missing — graceful fallback")
    }

    func testPublish_falseWhenUnavailable() {
        let bogusHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("v121-pub-fail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: bogusHome, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: bogusHome) }
        let share = ICloudDrivePairingShare(homeDirectory: bogusHome)
        let record = makeRecord()
        XCTAssertFalse(share.publish(record),
            "publish must return false when iCloud Drive unavailable")
    }

    func testPublishLookup_roundtripsAllFields() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let record = makeRecord()
        XCTAssertTrue(share.publish(record))
        guard let back = share.lookup(machineId: record.machineId) else {
            return XCTFail("lookup returned nil after publish")
        }
        XCTAssertEqual(back, record)
    }

    func testRecordFile_isOwnerOnly() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let record = makeRecord()
        XCTAssertTrue(share.publish(record))
        let file = share.directory.appendingPathComponent(
            "\(record.machineId.uuidString).json"
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600,
            "Record file must be 0o600 — public material but no point exposing it to other local users")
    }

    func testAllRecords_findsBothLocalAndPeerFiles() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mine = makeRecord(hostname: "Mine")
        let theirs = makeRecord(hostname: "Theirs")
        XCTAssertTrue(share.publish(mine))
        XCTAssertTrue(share.publish(theirs))
        let all = share.allRecords()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.machineId == mine.machineId })
        XCTAssertTrue(all.contains { $0.machineId == theirs.machineId })
    }

    func testAllRecords_emptyDirectory_returnsEmpty() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(share.allRecords(), [])
    }

    func testUnpublish_removesOnlyMyFile() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mine = makeRecord(hostname: "Mine")
        let theirs = makeRecord(hostname: "Theirs")
        XCTAssertTrue(share.publish(mine))
        XCTAssertTrue(share.publish(theirs))
        share.unpublish(machineId: mine.machineId)
        let remaining = share.allRecords()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.machineId, theirs.machineId,
            "unpublish must NOT touch other Macs' records")
    }

    func testLookup_unknownMachineId_returnsNil() throws {
        let (share, home) = try makeShareWithTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(share.lookup(machineId: UUID()))
    }

    // MARK: - PeerRecord shape compatibility with ICloudPairingShare

    /// V12RegressionTests already covers the type itself; this nails
    /// down that the file written by the Drive share decodes via the
    /// SAME type used by the Keychain share, so the dual-source path
    /// in AppEnvironment can use either record interchangeably.
    func testRecord_isSameTypeAsKeychainShare() {
        let r1: ICloudDrivePairingShare.PeerRecord = makeRecord()
        let r2: ICloudPairingShare.PeerRecord = r1     // type-alias check
        XCTAssertEqual(r2.machineId, r1.machineId)
    }

    // MARK: - helpers

    private func makeRecord(hostname: String = "TestMac") -> ICloudDrivePairingShare.PeerRecord {
        ICloudDrivePairingShare.PeerRecord(
            machineId: UUID(),
            hostname: hostname,
            username: "tester",
            sshPort: 22,
            publicKeyFingerprint: "SHA256:test-fingerprint-\(UUID().uuidString.prefix(8))",
            sshHostKey: "ssh-ed25519 AAAA test",
            advertisedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
