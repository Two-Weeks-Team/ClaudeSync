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
    ///
    /// v1.1 (SEC-003): nonces are now part of the derivation so that:
    /// (a) two pairings of the same physical keys produce different codes
    ///     (defends against pre-computation),
    /// (b) replaying a captured pairRequest on a fresh session no longer
    ///     produces a valid code (the nonce won't match).
    /// Both nonces default to empty Data for backwards compatibility with
    /// the v1.0.x wire format.
    public static func generateCode(
        initiatorPublicKey: Data,
        responderPublicKey: Data,
        initiatorNonce: Data = Data(),
        responderNonce: Data = Data()
    ) -> String {
        var combined = Data(capacity:
            initiatorPublicKey.count + responderPublicKey.count
            + initiatorNonce.count + responderNonce.count)
        combined.append(initiatorPublicKey)
        combined.append(responderPublicKey)
        combined.append(initiatorNonce)
        combined.append(responderNonce)

        let digest = SHA256.hash(data: combined)
        let prefix = digest.prefix(4)

        let value = prefix.reduce(into: UInt32(0)) { acc, byte in
            acc = (acc << 8) | UInt32(byte)
        }

        let truncated = value % 1_000_000
        return String(format: "%06u", truncated)
    }

    /// Generate a fresh per-session 16-byte nonce.
    public static func newNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }

    /// Hex encoding helper used to ferry nonces over the wire.
    public static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Hex decoding helper. Returns empty Data on malformed input so the
    /// caller can treat it as "no nonce" rather than throwing.
    public static func hexDecode(_ hex: String) -> Data {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return Data() }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue,
                  let lo = chars[i + 1].hexDigitValue else { return Data() }
            out.append(UInt8(hi * 16 + lo))
            i += 2
        }
        return out
    }
}
