import Foundation

/// Detects whether the running app has been granted Full Disk Access.
///
/// The probe attempts to list a known FDA-protected directory. We use
/// `~/Library/Cookies/` because:
///   * it always exists on every user account,
///   * it has no side-effects (read-only listing, contents discarded),
///   * it requires FDA on macOS 10.15+ — without FDA the read returns EPERM.
///
/// Reference: PRD FR-00b (lines 150-159).
public struct FullDiskAccessChecker: Sendable {
    public enum Status: Equatable, Sendable {
        case granted
        case denied
        /// Canary path is missing — cannot determine FDA status from this
        /// signal alone. Caller should fall back to another check or assume
        /// granted (FDA is the safer default to avoid blocking the user).
        case indeterminate(reason: String)
    }

    public let canaryURL: URL

    public init(canaryURL: URL? = nil) {
        if let canaryURL {
            self.canaryURL = canaryURL
        } else {
            self.canaryURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Cookies", isDirectory: true)
        }
    }

    public func check() -> Status {
        let fm = FileManager.default

        // If the canary path doesn't exist we cannot use it as a signal.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: canaryURL.path, isDirectory: &isDirectory) else {
            return .indeterminate(reason: "canary path missing: \(canaryURL.path)")
        }
        guard isDirectory.boolValue else {
            return .indeterminate(reason: "canary path is not a directory: \(canaryURL.path)")
        }

        do {
            _ = try fm.contentsOfDirectory(at: canaryURL, includingPropertiesForKeys: nil)
            return .granted
        } catch let error as NSError {
            // Operation not permitted (EPERM) → FDA not granted.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoPermissionError {
                return .denied
            }
            if error.domain == NSPOSIXErrorDomain, error.code == EPERM {
                return .denied
            }
            return .indeterminate(reason: "\(error.domain) \(error.code): \(error.localizedDescription)")
        }
    }
}
