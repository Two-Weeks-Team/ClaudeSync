import Foundation

/// Deep-link URLs for the macOS System Settings panes the onboarding flow
/// directs the user to. Centralised here so the URL strings can be unit-tested
/// without involving SwiftUI.
public enum SystemSettingsLink {
    /// General > Sharing pane (where Remote Login is toggled).
    /// Reference: PRD FR-00.
    public static let remoteLoginSharing: URL = URL(
        string: "x-apple.systempreferences:com.apple.preferences.sharing?Service_RemoteLogin"
    )!

    /// Privacy & Security > Full Disk Access.
    /// Reference: PRD FR-00b.
    public static let fullDiskAccess: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// Privacy & Security > Local Network (for the NSLocalNetworkUsageDescription prompt).
    public static let localNetwork: URL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )!
}
