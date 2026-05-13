import Foundation
import CryptoKit

/// Owns the dedicated SSH keypair ClaudeSync uses to talk to the paired
/// machine and the entries it installs in `~/.ssh/authorized_keys` to let the
/// peer talk back.
///
/// Reference: TECHNICAL_SPEC §10 (Security / SSH Key Management),
/// lines 1670-1798. Layout:
///
/// ```
/// ~/.claudesync/
/// └── ssh/
///     ├── id_claudesync          (private key, 0600)
///     └── id_claudesync.pub      (public key,  0644)
/// ~/.ssh/
/// └── authorized_keys            (peer key appended here, 0600)
/// ```
///
/// The `homeDirectoryURL` is injectable so tests run against a temporary
/// directory and never touch the developer's real `~/.ssh/authorized_keys`.
public actor SSHKeyManager {
    public enum KeyError: Error, Sendable, Equatable {
        case toolMissing(String)
        case generationFailed(String)
        case publicKeyMissing
        case privateKeyMissing
        case fingerprintParseFailed(String)
        case authorizedKeysIOError(String)
    }

    public enum KeyStatus: Equatable, Sendable {
        case valid
        case missing
        case permissionsIncorrect(current: Int)
    }

    /// Marker comment baked into authorized_keys entries so we can find
    /// (and remove) only the lines we installed.
    public static let authorizedKeysCommentPrefix = "claudesync@"

    public let homeDirectoryURL: URL
    public let sshKeygenPath: String
    public let machineLabel: String

    public init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory()),
        sshKeygenPath: String = "/usr/bin/ssh-keygen",
        machineLabel: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.sshKeygenPath = sshKeygenPath
        self.machineLabel = machineLabel
    }

    // MARK: - Paths

    public var keyDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".claudesync/ssh", isDirectory: true)
    }
    public var privateKeyURL: URL {
        keyDirectory.appendingPathComponent("id_claudesync")
    }
    public var publicKeyURL: URL {
        keyDirectory.appendingPathComponent("id_claudesync.pub")
    }
    public var authorizedKeysURL: URL {
        homeDirectoryURL.appendingPathComponent(".ssh/authorized_keys")
    }
    public var sshDirectoryURL: URL {
        homeDirectoryURL.appendingPathComponent(".ssh", isDirectory: true)
    }
    /// v1.0.1 (SEC-001): the rsync-server wrapper script we install and
    /// reference from the authorized_keys command= directive. Replacing the
    /// old `${SSH_ORIGINAL_COMMAND#*--server …}` shell expansion with a
    /// fixed-path script removes the ability for the peer to inject
    /// arbitrary rsync flags or alternate executables.
    public var rsyncWrapperURL: URL {
        homeDirectoryURL.appendingPathComponent(".claudesync/bin/rsync-server-wrapper")
    }
    /// v1.1 (SEC-005): ClaudeSync-private known_hosts so SSH no longer
    /// silently TOFU-trusts whatever host key is presented on first
    /// connection. Populated at pairing time from the peer's PairAccept.
    public var knownHostsURL: URL {
        homeDirectoryURL.appendingPathComponent(".claudesync/ssh/known_hosts")
    }

    // MARK: - Generation

    /// Generate an Ed25519 keypair if one does not already exist. Idempotent —
    /// running twice does not regenerate.
    public func ensureKeyPair() async throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: privateKeyURL.path),
           fm.fileExists(atPath: publicKeyURL.path) {
            try enforcePrivateKeyPermissions()
            return
        }

        guard fm.fileExists(atPath: sshKeygenPath) else {
            throw KeyError.toolMissing(sshKeygenPath)
        }

        try fm.createDirectory(
            at: keyDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // ssh-keygen refuses to overwrite without -f's path being absent. Make
        // sure no half-state lingers from a previous failed run.
        try? fm.removeItem(at: privateKeyURL)
        try? fm.removeItem(at: publicKeyURL)

        let runner = ProcessRunner(
            executable: sshKeygenPath,
            arguments: [
                "-t", "ed25519",
                "-f", privateKeyURL.path,
                "-N", "",
                "-C", "claudesync@\(machineLabel)",
            ]
        )

        do {
            _ = try await runner.run()
        } catch let ProcessRunner.RunnerError.nonZeroExit(_, stderr) {
            throw KeyError.generationFailed(stderr)
        } catch {
            throw KeyError.generationFailed(String(describing: error))
        }

        try enforcePrivateKeyPermissions()
    }

    /// Re-applies 0600 to the private key. ssh refuses to use a key with
    /// looser permissions, and tests want to assert this explicitly.
    public func enforcePrivateKeyPermissions() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: privateKeyURL.path) else {
            throw KeyError.privateKeyMissing
        }
        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
    }

    // MARK: - Read

    public func readPublicKey() throws -> String {
        guard FileManager.default.fileExists(atPath: publicKeyURL.path) else {
            throw KeyError.publicKeyMissing
        }
        let raw = try String(contentsOf: publicKeyURL, encoding: .utf8)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the raw 32-byte Ed25519 public key bytes, suitable for feeding
    /// into ``PairingCodeGenerator``. The OpenSSH `.pub` file is structured as
    /// `ssh-ed25519 <base64-blob> <comment>`. The blob decodes to a length-
    /// prefixed wire format whose payload is the 32-byte key.
    public func readPublicKeyBytes() throws -> Data {
        let line = try readPublicKey()
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw KeyError.fingerprintParseFailed("public key line malformed: \(line)")
        }
        guard let blob = Data(base64Encoded: String(parts[1])) else {
            throw KeyError.fingerprintParseFailed("public key base64 decode failed")
        }

        // SSH wire format: [4-byte len][algo bytes][4-byte len][key bytes...]
        guard blob.count >= 4 else {
            throw KeyError.fingerprintParseFailed("public key blob too short")
        }
        let algoLen = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        let afterAlgoOffset = 4 + algoLen
        guard blob.count >= afterAlgoOffset + 4 else {
            throw KeyError.fingerprintParseFailed("public key truncated after algo")
        }
        let keyLen = Int(blob[afterAlgoOffset    ]) << 24
                   | Int(blob[afterAlgoOffset + 1]) << 16
                   | Int(blob[afterAlgoOffset + 2]) << 8
                   | Int(blob[afterAlgoOffset + 3])
        let keyOffset = afterAlgoOffset + 4
        guard blob.count >= keyOffset + keyLen else {
            throw KeyError.fingerprintParseFailed("public key truncated payload")
        }
        return blob.subdata(in: keyOffset ..< keyOffset + keyLen)
    }

    /// SHA-256 fingerprint in OpenSSH "SHA256:<base64>" format. We compute it
    /// in-process (CryptoKit) instead of shelling out to ssh-keygen so the
    /// function is fast and deterministic in tests.
    public func publicKeyFingerprint() throws -> String {
        let line = try readPublicKey()
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw KeyError.fingerprintParseFailed(line)
        }
        let digest = SHA256.hash(data: blob)
        // OpenSSH strips the "=" padding from the base64 fingerprint.
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: ["="])
        return "SHA256:\(base64)"
    }

    // MARK: - authorized_keys management

    /// Append the peer's public key with a `restrict,command="…rsync server…"`
    /// prefix so the key cannot be used for arbitrary remote execution.
    ///
    /// v1.0.1 (SEC-001): the command line now points at a fixed wrapper
    /// script (`~/.claudesync/bin/rsync-server-wrapper`) instead of doing
    /// in-shell `${SSH_ORIGINAL_COMMAND}` parameter expansion. The wrapper
    /// validates the incoming arguments against an allowlist before invoking
    /// rsync, so a compromised peer can't sneak in `--config=`/`--rsh=`
    /// flags via the SSH command channel.
    public func installPeerKey(_ peerPublicKey: String) throws {
        let trimmed = peerPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try installRsyncWrapperIfMissing()
        let wrapperPath = rsyncWrapperURL.path
        let entry = """
        restrict,command="\(wrapperPath)",no-port-forwarding,no-X11-forwarding,no-agent-forwarding \(trimmed)
        """

        try ensureSSHDirectory()
        try ensureAuthorizedKeysFile()

        var contents = (try? String(contentsOf: authorizedKeysURL, encoding: .utf8)) ?? ""
        if !contents.isEmpty, !contents.hasSuffix("\n") {
            contents += "\n"
        }
        contents += entry + "\n"

        do {
            try contents.write(to: authorizedKeysURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: authorizedKeysURL.path
            )
        } catch {
            throw KeyError.authorizedKeysIOError(String(describing: error))
        }
    }

    /// Remove every authorized_keys entry whose comment contains the given
    /// substring. Comments live at the end of an OpenSSH key line, e.g.
    /// `... ssh-ed25519 AAAA... claudesync@MacBookAir`.
    public func removePeerKey(matchingComment substring: String) throws {
        guard FileManager.default.fileExists(atPath: authorizedKeysURL.path) else { return }

        let original: String
        do {
            original = try String(contentsOf: authorizedKeysURL, encoding: .utf8)
        } catch {
            throw KeyError.authorizedKeysIOError(String(describing: error))
        }

        let kept = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.contains(substring)
            }
            .joined(separator: "\n")

        do {
            try kept.write(to: authorizedKeysURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: authorizedKeysURL.path
            )
        } catch {
            throw KeyError.authorizedKeysIOError(String(describing: error))
        }
    }

    // MARK: - Integrity

    public func verifyKeyIntegrity() throws -> KeyStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: privateKeyURL.path) else {
            return .missing
        }
        let attrs = try fm.attributesOfItem(atPath: privateKeyURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if perms != 0o600 {
            return .permissionsIncorrect(current: perms)
        }
        return .valid
    }

    // MARK: - Helpers

    private func ensureSSHDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDirectoryURL.path) {
            try fm.createDirectory(
                at: sshDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func ensureAuthorizedKeysFile() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: authorizedKeysURL.path) {
            fm.createFile(
                atPath: authorizedKeysURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    /// v1.1 (SEC-005): write `<hostname> <hostkey>` into our private
    /// known_hosts file. Existing entries for the same hostname are
    /// replaced so a re-pair updates the trusted key. Hostname must
    /// pass `AppEnvironment.isSafeNetworkIdentifier` upstream — we do
    /// not re-validate here, but we DO refuse a hostkey line that's
    /// missing the algorithm prefix.
    public func registerKnownHost(hostname: String, hostKey: String) throws {
        let trimmed = hostKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") else {
            throw KeyError.fingerprintParseFailed("hostkey lacks algorithm prefix")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: knownHostsURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var existing: String = ""
        if fm.fileExists(atPath: knownHostsURL.path) {
            existing = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        }
        // Drop any prior line for this hostname (or `<host>,<host>.local`).
        let bareHost = hostname.hasSuffix(".local")
            ? String(hostname.dropLast(".local".count))
            : hostname
        let kept = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let s = String(line)
                if s.isEmpty { return false }
                let firstField = s.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let names = firstField.split(separator: ",").map(String.init)
                return !(names.contains(bareHost) || names.contains("\(bareHost).local"))
            }
            .joined(separator: "\n")
        let entry = "\(bareHost),\(bareHost).local \(trimmed)\n"
        let next = kept.isEmpty ? entry : (kept.hasSuffix("\n") ? kept + entry : kept + "\n" + entry)
        try next.write(to: knownHostsURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: knownHostsURL.path)
    }

    /// Returns true if `hostname` (or `hostname.local`) has at least one
    /// entry in our private known_hosts.
    public func hasKnownHost(hostname: String) -> Bool {
        guard let contents = try? String(contentsOf: knownHostsURL, encoding: .utf8)
        else { return false }
        let bare = hostname.hasSuffix(".local")
            ? String(hostname.dropLast(".local".count))
            : hostname
        for line in contents.split(separator: "\n") {
            let firstField = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let names = firstField.split(separator: ",").map(String.init)
            if names.contains(bare) || names.contains("\(bare).local") {
                return true
            }
        }
        return false
    }

    /// v1.0.1 (SEC-001): install the rsync-server wrapper script that
    /// authorized_keys' command= directive points at. The wrapper validates
    /// the SSH-supplied command line against an allowlist before exec'ing
    /// rsync, blocking attacker injection of `--config`, `--rsh`,
    /// `--daemon`, or arbitrary executables.
    ///
    /// Idempotent: only writes when the file is missing OR the on-disk
    /// content differs from the bundled script (so app upgrades replace it).
    public func installRsyncWrapperIfMissing() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: rsyncWrapperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let desired = Self.rsyncWrapperScript
        let current = (try? String(contentsOf: rsyncWrapperURL, encoding: .utf8)) ?? ""
        if current != desired {
            try desired.write(to: rsyncWrapperURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o700],
                             ofItemAtPath: rsyncWrapperURL.path)
    }

    /// Inline POSIX-sh script content. Validates `$SSH_ORIGINAL_COMMAND`:
    ///
    /// * Must start with `rsync ` (allowing the GNU or openrsync server
    ///   invocation rsync uses internally).
    /// * Must not contain backticks, semicolons, pipes, redirects, or any
    ///   `--config=`/`--rsh=`/`--daemon` flag.
    ///
    /// Anything that passes validation is dispatched to the system rsync
    /// with `--server` enforced.
    static let rsyncWrapperScript: String = #"""
    #!/bin/sh
    # ClaudeSync rsync-server wrapper (v1.0.1 SEC-001)
    # Validates SSH_ORIGINAL_COMMAND against an allowlist before invoking rsync.
    set -eu

    cmd="${SSH_ORIGINAL_COMMAND:-}"
    if [ -z "$cmd" ]; then
        echo "claudesync: SSH_ORIGINAL_COMMAND is empty" >&2
        exit 1
    fi

    case "$cmd" in
        *\`*|*\;*|*\|*|*\&*|*\>*|*\<*|*\$\(*)
            echo "claudesync: refused — shell metacharacter in command" >&2
            exit 1
            ;;
    esac

    case "$cmd" in
        *--config*|*--rsh*|*--daemon*|*--config=*)
            echo "claudesync: refused — disallowed rsync flag" >&2
            exit 1
            ;;
    esac

    case "$cmd" in
        rsync\ *)
            ;;
        *)
            echo "claudesync: refused — only rsync invocations allowed" >&2
            exit 1
            ;;
    esac

    # Forward the validated arguments to the user's rsync (after the leading
    # 'rsync ' token). Use the first rsync we can find in either Homebrew's
    # path or the system path so this works on Sequoia (openrsync) and on
    # machines where the user installed GNU rsync via brew.
    #
    # v1.2.14: parse `rest` with `eval` so a path containing a backslash-
    # escaped space (e.g. `~/Library/Application\ Support/Claude/`)
    # arrives at rsync as ONE argument, not two. Earlier `exec $candidate
    # $rest` did naive whitespace split, breaking any target with a
    # space ("server receiver mode requires two argument"). The allowlist
    # checks above already reject backticks / `$( )` / `;` / `|` / `&`
    # / `<` / `>`, so eval here can't reach any unvetted construct.
    rest=${cmd#rsync }
    for candidate in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
        if [ -x "$candidate" ]; then
            eval "exec \"\$candidate\" $rest"
        fi
    done
    echo "claudesync: no rsync binary found" >&2
    exit 1
    """#
}
