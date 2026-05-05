import XCTest
@testable import ClaudeSync

/// Security-critical: any defect here is a MITM vulnerability. Coverage target
/// per TEST_STRATEGY §8 is 100%.
final class PairingCodeGeneratorTests: XCTestCase {

    // MARK: - Determinism

    func testSameKeys_produceSameCode() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)

        let code1 = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        let code2 = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)

        XCTAssertEqual(code1, code2, "Same input must always produce the same code")
    }

    // MARK: - MITM detection

    func testDifferentKeys_produceDifferentCode() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)
        let attackerKey = Data("attackerKeyZ".utf8)

        let legitimate = PairingCodeGenerator.generateCode(
            initiatorPublicKey: keyA, responderPublicKey: keyB
        )
        let mitm = PairingCodeGenerator.generateCode(
            initiatorPublicKey: keyA, responderPublicKey: attackerKey
        )

        XCTAssertNotEqual(legitimate, mitm,
            "An attacker substituting the responder key must produce a different code")
    }

    // MARK: - Format

    func testCode_isExactlySixDecimalDigits() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)

        let code = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)

        XCTAssertEqual(code.count, 6, "Code must always be 6 characters")
        XCTAssertTrue(code.allSatisfy { $0.isNumber }, "Code must consist only of decimal digits")
    }

    func testCode_isZeroPadded_whenHashStartsWithSmallValue() {
        // Search for an input pair that yields a code < 100000 so we can
        // assert zero-padding rather than mocking SHA-256. This is a tiny
        // brute-force loop (deterministic seed); the test is fast.
        for i in 0..<10_000 {
            let keyA = Data("seedA-\(i)".utf8)
            let keyB = Data("seedB-\(i)".utf8)
            let code = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
            if code.first == "0" {
                XCTAssertEqual(code.count, 6, "Even when leading zeros are needed, code stays 6 chars")
                return
            }
        }
        XCTFail("Did not find a leading-zero code in 10,000 iterations — extremely unlikely; algorithm may be wrong")
    }

    // MARK: - Order matters (initiator vs responder)

    func testOrderMatters_swappingInitiatorAndResponder_changesCode() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)

        let codeAB = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        let codeBA = PairingCodeGenerator.generateCode(initiatorPublicKey: keyB, responderPublicKey: keyA)

        XCTAssertNotEqual(codeAB, codeBA,
            "Initiator/responder ordering must be part of the hash so both peers agree")
    }

    // MARK: - Edge cases

    func testEmptyKeys_doNotCrash() {
        let code = PairingCodeGenerator.generateCode(
            initiatorPublicKey: Data(), responderPublicKey: Data()
        )
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })
    }

    func testRealisticEd25519PublicKeyLength_produces6Digits() {
        // Ed25519 raw public keys are 32 bytes.
        let keyA = Data(repeating: 0xA1, count: 32)
        let keyB = Data(repeating: 0xB2, count: 32)
        let code = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })
    }
}
