import Foundation
import CryptoKit

/// Tamper detection for `preferences.json`. v1.1 (SEC-009): a local-user-only
/// HMAC key is generated once and kept at `~/.claudesync/.machine-key`
/// (0o600). Every preferences write also writes a hex sidecar at
/// `~/.claudesync/preferences.json.sig` containing
/// `HMAC-SHA256(key, json-bytes)`. On load we recompute and reject the
/// payload if the signature is missing or doesn't match — at which point we
/// fall back to defaults and surface a warning instead of silently honoring
/// the modified file (which could, for instance, swap in a malicious
/// `pairedPeer.hostname` that points rsync at an attacker-controlled box).
public struct PreferencesIntegrity {

    public let machineKeyURL: URL
    public let signatureURL: URL
    private let logger: AppLogger

    public init(preferencesURL: URL,
                machineKeyURL: URL? = nil,
                logger: AppLogger = .shared) {
        let dir = preferencesURL.deletingLastPathComponent()
        self.machineKeyURL = machineKeyURL ?? dir.appendingPathComponent(".machine-key")
        self.signatureURL = preferencesURL
            .deletingLastPathComponent()
            .appendingPathComponent(preferencesURL.lastPathComponent + ".sig")
        self.logger = logger
    }

    /// Returns the local HMAC key, generating one if missing. Always
    /// re-enforces 0o600 permissions on the key file.
    public func loadOrCreateKey() throws -> SymmetricKey {
        let fm = FileManager.default
        try fm.createDirectory(at: machineKeyURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: machineKeyURL), data.count == 32 {
            try? fm.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: machineKeyURL.path)
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try raw.write(to: machineKeyURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600],
                             ofItemAtPath: machineKeyURL.path)
        return key
    }

    /// Compute hex(HMAC-SHA256(key, payload)).
    public func sign(_ payload: Data, using key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomically persist the signature next to the preferences file.
    public func writeSignature(for payload: Data, using key: SymmetricKey) throws {
        let hex = sign(payload, using: key)
        try hex.write(to: signatureURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: signatureURL.path
        )
    }

    /// Constant-time comparison so a timing side-channel can't leak the
    /// expected signature byte-by-byte. Returns true if the on-disk sig
    /// matches the recomputed value, false on mismatch / missing file.
    public func verify(payload: Data, using key: SymmetricKey) -> Bool {
        guard let stored = try? String(contentsOf: signatureURL, encoding: .utf8) else {
            return false
        }
        let storedHex = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedHex = sign(payload, using: key)
        return Self.constantTimeEqual(storedHex, expectedHex)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) {
            diff |= x ^ y
        }
        return diff == 0
    }
}
