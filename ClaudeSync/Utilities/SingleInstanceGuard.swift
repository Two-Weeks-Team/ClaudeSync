import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// v1.1: prevents two copies of ClaudeSync from running on the same Mac.
///
/// Two failure modes we explicitly defend against:
///
/// 1. **Bonjour port collision** — `NWListener` would refuse to bind, the
///    second instance would emit a `.failed` state, and discovery would
///    silently die for the second copy.
/// 2. **Doubled FSEvents streams** — both copies would react to every
///    file change and enqueue duplicate rsync jobs, cascading into a
///    write storm on the receiver.
///
/// The check runs at app launch. If another running process with the
/// same bundle identifier is found, we bring it to the front (so the user
/// sees the existing menu-bar tray) and terminate ourselves cleanly.
///
/// We also drop a sentinel file at `~/.claudesync/.app.pid` containing
/// our PID. Stale files (the recorded PID is no longer alive) are removed.
@MainActor
public enum SingleInstanceGuard {

    public enum Outcome: Equatable, Sendable {
        case primary
        case duplicateAlreadyRunning(otherPid: Int32)
    }

    /// Inspect the running-applications list AND a PID sentinel file.
    /// Returns `.primary` if we're the only one, or
    /// `.duplicateAlreadyRunning` if another instance is alive.
    ///
    /// `includeRunningAppsScan: false` skips the NSRunningApplication
    /// scan and checks only the sentinel file. Used by unit tests where
    /// any other ClaudeSync.app the developer happens to be running on
    /// the same Mac would otherwise trip the assertion.
    public static func check(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        includeRunningAppsScan: Bool = true
    ) -> Outcome {
        // 1) Process-list scan (only available with AppKit, which is fine
        //    since this is a macOS-only app).
        #if canImport(AppKit)
        if includeRunningAppsScan, let bundleId = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId)
                .filter { $0.processIdentifier != me && $0.processIdentifier > 0 }
            if let other = others.first {
                return .duplicateAlreadyRunning(otherPid: other.processIdentifier)
            }
        }
        #endif

        // 2) PID sentinel file — defends against the rare case where
        //    NSRunningApplication is slow to publish the new launch.
        let sentinel = homeDirectory.appendingPathComponent(".claudesync/.app.pid")
        if let data = try? Data(contentsOf: sentinel),
           let s = String(data: data, encoding: .utf8),
           let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != ProcessInfo.processInfo.processIdentifier,
           kill(pid, 0) == 0 {
            // Process exists and isn't us.
            return .duplicateAlreadyRunning(otherPid: pid)
        }
        return .primary
    }

    /// Atomically write our PID into the sentinel file. Idempotent.
    /// Idempotent even when called from a re-launched primary that just
    /// reaped a stale sentinel.
    public static func claimSentinel(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        let dir = homeDirectory.appendingPathComponent(".claudesync", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = dir.appendingPathComponent(".app.pid")
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try? pid.write(to: sentinel, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sentinel.path
        )
    }

    /// Remove the sentinel file on clean shutdown.
    public static func releaseSentinel(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        let sentinel = homeDirectory.appendingPathComponent(".claudesync/.app.pid")
        try? FileManager.default.removeItem(at: sentinel)
    }

    /// Convenience wrapper used from the App scene init: if a duplicate
    /// is found, activate it and terminate self. Otherwise claim the
    /// sentinel and return.
    public static func enforce() {
        // Skip during XCTest runs — xcodebuild test launches the host
        // app via `lsopen`, and if any production ClaudeSync is also
        // running on this Mac the guard would shut us down before any
        // test can connect to the runner.
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["CLAUDESYNC_DISABLE_SINGLE_INSTANCE"] == "1"
        {
            return
        }
        switch check() {
        case .primary:
            claimSentinel()
        case .duplicateAlreadyRunning(let otherPid):
            #if canImport(AppKit)
            if let bundleId = Bundle.main.bundleIdentifier,
               let other = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId)
                .first(where: { $0.processIdentifier == otherPid }) {
                other.activate()
            }
            #endif
            // Print to stderr so launching from a terminal shows why.
            FileHandle.standardError.write(Data(
                "ClaudeSync: another instance (pid \(otherPid)) is already running. Activating it and exiting.\n".utf8
            ))
            // Brief delay so the activation request gets dispatched before
            // we exit — otherwise NSRunningApplication.activate is racy.
            Thread.sleep(forTimeInterval: 0.1)
            exit(0)
        }
    }
}
