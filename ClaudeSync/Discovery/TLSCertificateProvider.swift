import Foundation
import Security
import Network
import CryptoKit

/// v1.1 (SEC-002): provides a long-lived self-signed TLS certificate +
/// `SecIdentity` so `NWConnection`s in the control plane can negotiate
/// TLS 1.2/1.3 instead of speaking plaintext.
///
/// The certificate is generated via `/usr/bin/openssl` (always present on
/// macOS) the first time the app launches and persisted to
/// `~/.claudesync/tls/`. Verification of the *peer's* certificate is the
/// caller's responsibility — `TLSCertificateProvider.makeOptions` installs
/// a custom verify block that:
///   * accepts any cert if `pinnedFingerprint` is nil (first/unpaired
///     handshake — the 6-digit code + nonce + known_hosts layers above
///     handle authenticity);
///   * accepts only certs whose SHA-256 fingerprint matches
///     `pinnedFingerprint` once the peer is paired.
@MainActor
public final class TLSCertificateProvider {

    public enum TLSError: Error, Sendable {
        case openSSLMissing
        case opensslFailed(String)
        case pkcs12ImportFailed(OSStatus)
        case identityNotFound
    }

    public let directory: URL
    public let certPEMURL: URL
    public let keyPEMURL: URL
    public let p12URL: URL
    public let p12Passphrase: String
    private let logger: AppLogger

    /// Cached identity so repeat `loadOrCreateIdentity()` calls don't
    /// re-import the same PKCS12 blob on every NWConnection.
    private var cachedIdentity: SecIdentity?

    public init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
                logger: AppLogger = .shared) {
        self.directory = homeDirectory.appendingPathComponent(".claudesync/tls",
                                                              isDirectory: true)
        self.certPEMURL = directory.appendingPathComponent("server.crt")
        self.keyPEMURL = directory.appendingPathComponent("server.key")
        self.p12URL = directory.appendingPathComponent("server.p12")
        // The PKCS12 passphrase is stored alongside the file. macOS's
        // SecPKCS12Import requires *some* passphrase even for local files.
        // We treat the whole directory as 0o700 so other local users
        // can't read either the key or the passphrase.
        self.p12Passphrase = "claudesync-local"
        self.logger = logger
    }

    /// Idempotent generator. Returns a usable SecIdentity, creating the
    /// underlying P-256 EC keypair + self-signed cert via openssl on first
    /// invocation.
    public func loadOrCreateIdentity() async throws -> SecIdentity {
        if let cached = cachedIdentity { return cached }
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: p12URL.path) {
            try await generateCertificate()
        }
        let identity = try importPKCS12()
        cachedIdentity = identity
        return identity
    }

    /// Build NWProtocolTLS.Options ready to drop into NWParameters.
    /// `pinnedFingerprint` (hex, lowercase, no separators) is the SHA-256
    /// of the peer's DER-encoded certificate. Pass `nil` for the
    /// pre-pairing handshake.
    public func makeOptions(pinnedFingerprint: String?) async throws -> NWProtocolTLS.Options {
        let identity = try await loadOrCreateIdentity()
        let secIdentity = sec_identity_create(identity)!
        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_local_identity(secOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)

        // Custom verify block: pin against the cached peer fingerprint
        // when one is available, otherwise accept (TOFU first-pairing).
        let pin = pinnedFingerprint
        sec_protocol_options_set_verify_block(secOptions, { _, sec_trust, completion in
            if let pin {
                let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                let ok = Self.trustMatchesPin(trust: trust, pin: pin)
                completion(ok)
            } else {
                completion(true)
            }
        }, .main)
        return tlsOptions
    }

    /// Compute the SHA-256 fingerprint (hex) of our own server certificate.
    /// Sent over the wire during pairing so the peer can pin us next time.
    public func ownCertificateFingerprint() throws -> String {
        let pem = try String(contentsOf: certPEMURL, encoding: .utf8)
        let der = try Self.derFromPEM(pem)
        let digest = SHA256.hash(data: der)
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private func ensureDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
    }

    private func generateCertificate() async throws {
        let openssl = Self.findOpenSSL()
        guard FileManager.default.isExecutableFile(atPath: openssl) else {
            throw TLSError.openSSLMissing
        }
        let runner = ProcessRunner(executable: openssl, arguments: [
            "req", "-x509",
            "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:P-256",
            "-days", "3650",
            "-nodes",
            "-keyout", keyPEMURL.path,
            "-out", certPEMURL.path,
            "-subj", "/CN=ClaudeSync-\(UUID().uuidString)"
        ])
        do {
            _ = try await runner.run()
        } catch {
            throw TLSError.opensslFailed(String(describing: error))
        }
        // Bundle into PKCS12 (Network.framework needs SecIdentity which
        // is fed by SecPKCS12Import).
        let p12Runner = ProcessRunner(executable: openssl, arguments: [
            "pkcs12", "-export",
            "-inkey", keyPEMURL.path,
            "-in", certPEMURL.path,
            "-out", p12URL.path,
            "-password", "pass:\(p12Passphrase)",
            "-name", "ClaudeSync"
        ])
        do {
            _ = try await p12Runner.run()
        } catch {
            throw TLSError.opensslFailed(String(describing: error))
        }
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: keyPEMURL.path)
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: p12URL.path)
        logger.info("Generated TLS certificate at \(certPEMURL.path)",
                    category: "tls")
    }

    private func importPKCS12() throws -> SecIdentity {
        let data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Passphrase
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityValue = first[kSecImportItemIdentity as String]
        else {
            throw TLSError.pkcs12ImportFailed(status)
        }
        // CFTypeRef cast — SecPKCS12Import returns SecIdentityRef
        return identityValue as! SecIdentity
    }

    /// Walk SecTrust's evaluated certificate chain and check whether the
    /// leaf SHA-256 matches the pinned fingerprint. We deliberately
    /// ignore the system trust evaluation: our certs are self-signed
    /// and the *whole* point of pinning is that we don't need a CA.
    static func trustMatchesPin(trust: SecTrust, pin: String) -> Bool {
        let count = SecTrustGetCertificateCount(trust)
        guard count > 0 else { return false }
        // Prefer SecTrustCopyCertificateChain when available (macOS 12+);
        // we deploy to macOS 15 so this is always present.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        let hex = Data(digest).map { String(format: "%02x", $0) }.joined()
        return hex.caseInsensitiveCompare(pin) == .orderedSame
    }

    static func findOpenSSL() -> String {
        for c in ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "/usr/bin/openssl"
    }

    /// Strip PEM markers + base64-decode to DER for hashing.
    static func derFromPEM(_ pem: String) throws -> Data {
        let body = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw TLSError.opensslFailed("Could not decode PEM body")
        }
        return der
    }
}
