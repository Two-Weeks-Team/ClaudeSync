import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the menu bar UI can toggle "Launch at Login"
/// without leaking ServiceManagement types into the view layer.
///
/// Requires macOS 13+. Below that we degrade to a no-op (the toggle stays
/// hidden in the UI). On modern macOS the system records the registration in
/// the user's Login Items panel; the user can revoke it from System Settings
/// and we observe the change via `status`.
@MainActor
public final class LaunchAtLoginController {

    public enum LaunchStatus: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        case notSupported
    }

    private let logger: AppLogger

    public init(logger: AppLogger = .shared) {
        self.logger = logger
    }

    /// Current status of the main app's login item registration.
    public var status: LaunchStatus {
        guard #available(macOS 13.0, *) else { return .notSupported }
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .requiresApproval:  return .requiresApproval
        case .notRegistered:     return .disabled
        case .notFound:          return .disabled
        @unknown default:        return .disabled
        }
    }

    public var isEnabled: Bool {
        status == .enabled
    }

    /// Register or unregister the main app as a login item. Returns the new
    /// status after the call.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LaunchStatus {
        guard #available(macOS 13.0, *) else { return .notSupported }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Launch at login: registered", category: "launch")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Launch at login: unregistered", category: "launch")
            }
        } catch {
            logger.warning("Launch at login toggle failed: \(error)",
                           category: "launch")
        }
        return status
    }
}
