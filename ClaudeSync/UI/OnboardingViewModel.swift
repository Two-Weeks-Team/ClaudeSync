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

    public init(
        preflight: RemoteLoginPreflight = RemoteLoginPreflight(),
        fdaChecker: FullDiskAccessChecker = FullDiskAccessChecker()
    ) {
        self.preflight = preflight
        self.fdaChecker = fdaChecker
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
}

// AppKit import for NSWorkspace
#if canImport(AppKit)
import AppKit
#endif
