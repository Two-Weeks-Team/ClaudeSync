import Foundation
import CryptoKit

/// Derives the 6-digit visual confirmation code shown on both screens during
/// pairing. Both machines independently compute the same code from the
/// exchanged public keys; if an attacker substitutes a key during the Bonjour
/// handshake the codes will diverge and the user will refuse to accept.
///
/// ## Algorithm
/// 1. Concatenate the raw initiator public-key bytes followed by the raw
///    responder public-key bytes — the order must be agreed up front so both
///    sides hash the same input.
/// 2. SHA-256 the concatenated buffer.
/// 3. Read the first 4 bytes as a big-endian `UInt32`.
/// 4. Take that value modulo 1_000_000 and zero-pad to 6 decimal digits.
///
/// Reference: TECHNICAL_SPEC.md §5 (Pairing Protocol), lines 707-734.
public enum PairingCodeGenerator {
    /// Produce the 6-digit pairing code for the given key pair. Always
    /// returns a 6-character string of decimal digits, zero-padded.
    public static func generateCode(
        initiatorPublicKey: Data,
        responderPublicKey: Data
    ) -> String {
        var combined = Data(capacity: initiatorPublicKey.count + responderPublicKey.count)
        combined.append(initiatorPublicKey)
        combined.append(responderPublicKey)

        let digest = SHA256.hash(data: combined)
        let prefix = digest.prefix(4)

        let value = prefix.reduce(into: UInt32(0)) { acc, byte in
            acc = (acc << 8) | UInt32(byte)
        }

        let truncated = value % 1_000_000
        return String(format: "%06u", truncated)
    }
}
