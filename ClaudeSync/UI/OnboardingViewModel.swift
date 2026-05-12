import Foundation
import SwiftUI

/// State + actions for the first-launch onboarding flow. Pulled out of the
/// SwiftUI view so the state machine can be unit-tested without rendering UI.
///
/// Step progression (PRD FR-03 + FR-00 + FR-00b):
///
///   welcome → remoteLogin → fullDiskAccess → discovery → pairingCode → done
@MainActor
@Observable
public final class OnboardingViewModel {

    public enum Step: Equatable, Sendable {
        case welcome
        case remoteLogin(RemoteLoginPreflight.Outcome?)
        case fullDiskAccess(FullDiskAccessChecker.Status?)
        case discovery
        case pairingCode(PairingManager.State)
        case done
    }

    public private(set) var step: Step = .welcome
    public private(set) var lastError: String?

    private let preflight: RemoteLoginPreflight
    private let fdaChecker: FullDiskAccessChecker

    /// Pluggable pairing actions — set by AppEnvironment once a PairingManager
    /// instance exists (i.e. after a peer has been discovered). The view calls
    /// these closures on button taps without knowing about PairingManager.
    public var onAcceptPair: (() async -> Void)?
    public var onConfirmPair: (() async -> Void)?
    public var onRejectPair:  ((String) async -> Void)?

    public init(
        preflight: RemoteLoginPreflight = RemoteLoginPreflight(),
        fdaChecker: FullDiskAccessChecker = FullDiskAccessChecker()
    ) {
        self.preflight = preflight
        self.fdaChecker = fdaChecker
    }

    public func acceptPair() async {
        await onAcceptPair?()
    }
    public func confirmPair() async {
        await onConfirmPair?()
    }
    public func rejectPair(reason: String) async {
        await onRejectPair?(reason)
    }

    // MARK: - Step transitions

    public func advanceFromWelcome() {
        step = .remoteLogin(nil)
    }

    public func runRemoteLoginCheck() async {
        let outcome = await preflight.checkLocalOnly()
        step = .remoteLogin(outcome)
    }

    public func advanceFromRemoteLogin() {
        guard case .remoteLogin(let outcome?) = step, outcome.isReady else { return }
        step = .fullDiskAccess(nil)
    }

    public func runFullDiskAccessCheck() {
        step = .fullDiskAccess(fdaChecker.check())
    }

    public func advanceFromFullDiskAccess() {
        guard case .fullDiskAccess(let status?) = step else { return }
        // Allow proceeding on .granted or .indeterminate (we can't always
        // detect FDA reliably; .indeterminate must not block the user).
        switch status {
        case .granted, .indeterminate:
            step = .discovery
        case .denied:
            return
        }
    }

    public func discoveryFoundPeer() {
        guard case .discovery = step else { return }
        step = .pairingCode(.idle)
    }

    public func updatePairingState(_ pairingState: PairingManager.State) {
        if case .pairingCode = step {
            step = .pairingCode(pairingState)
            if case .completed = pairingState {
                step = .done
            }
        }
    }

    public func reset() {
        step = .welcome
        lastError = nil
    }

    // MARK: - Deep link helpers

    public func openSystemSettingsForRemoteLogin() {
        NSWorkspace.shared.open(SystemSettingsLink.remoteLoginSharing)
    }

    public func openSystemSettingsForFullDiskAccess() {
        NSWorkspace.shared.open(SystemSettingsLink.fullDiskAccess)
    }

    public func openSystemSettingsForLocalNetwork() {
        NSWorkspace.shared.open(SystemSettingsLink.localNetwork)
    }

    public func openSystemSettingsForFirewall() {
        NSWorkspace.shared.open(SystemSettingsLink.firewall)
    }

    // MARK: - Pairing retry

    /// After a failed/rejected pairing the AppEnvironment has torn down the
    /// PairingManager; bounce the wizard back to the discovery step so the
    /// user can pick the peer and hit "Pair" again without restarting the
    /// whole onboarding flow.
    public func retryPairing() {
        switch step {
        case .pairingCode: step = .discovery
        default: break
        }
    }
}

// AppKit import for NSWorkspace
#if canImport(AppKit)
import AppKit
#endif
