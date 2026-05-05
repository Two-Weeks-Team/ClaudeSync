import XCTest
import Network
@testable import ClaudeSync

final class PeerInfoDecodingTests: XCTestCase {

    func testDecode_validTXT_returnsPeerInfo() {
        var txt = NWTXTRecord()
        txt[BonjourKeys.version]     = "1"
        txt[BonjourKeys.machineId]   = "550e8400-e29b-41d4-a716-446655440000"
        txt[BonjourKeys.hostname]    = "MacBookAir"
        txt[BonjourKeys.username]    = "kim"
        txt[BonjourKeys.sshPort]     = "22"
        txt[BonjourKeys.paired]      = "1"
        txt[BonjourKeys.publicKeyFP] = "SHA256:abc"

        let info = PeerInfo.decode(txt: txt, endpointDescription: "test")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.hostname, "MacBookAir")
        XCTAssertEqual(info?.username, "kim")
        XCTAssertEqual(info?.sshPort, 22)
        XCTAssertEqual(info?.isPaired, true)
        XCTAssertEqual(info?.publicKeyFingerprint, "SHA256:abc")
        XCTAssertEqual(info?.sshAddress, "kim@MacBookAir.local")
    }

    func testDecode_missingMachineId_returnsNil() {
        var txt = NWTXTRecord()
        txt[BonjourKeys.hostname] = "MacBookAir"
        txt[BonjourKeys.username] = "kim"
        txt[BonjourKeys.sshPort]  = "22"
        XCTAssertNil(PeerInfo.decode(txt: txt, endpointDescription: ""))
    }

    func testDecode_invalidUUID_returnsNil() {
        var txt = NWTXTRecord()
        txt[BonjourKeys.machineId] = "not-a-uuid"
        txt[BonjourKeys.hostname]  = "host"
        txt[BonjourKeys.username]  = "user"
        txt[BonjourKeys.sshPort]   = "22"
        XCTAssertNil(PeerInfo.decode(txt: txt, endpointDescription: ""))
    }

    func testDecode_invalidPort_returnsNil() {
        var txt = NWTXTRecord()
        txt[BonjourKeys.machineId] = UUID().uuidString
        txt[BonjourKeys.hostname]  = "host"
        txt[BonjourKeys.username]  = "user"
        txt[BonjourKeys.sshPort]   = "not-a-number"
        XCTAssertNil(PeerInfo.decode(txt: txt, endpointDescription: ""))
    }

    func testDecode_missingPaired_defaultsToFalse() {
        var txt = NWTXTRecord()
        txt[BonjourKeys.machineId] = UUID().uuidString
        txt[BonjourKeys.hostname]  = "host"
        txt[BonjourKeys.username]  = "user"
        txt[BonjourKeys.sshPort]   = "22"
        let info = PeerInfo.decode(txt: txt, endpointDescription: "")
        XCTAssertNotNil(info)
        XCTAssertFalse(info!.isPaired)
    }
}
