import SwiftUI

/// First-launch onboarding window — guides the user through preflight checks
/// and the initial pairing handshake.
///
/// Shown via a `WindowGroup` scene routed by `AppEnvironment.needsOnboarding`.
///
/// v1.0.1 (RCA-C1): the view now uses the OnboardingViewModel owned by
/// AppEnvironment so the Accept/Confirm/Reject buttons actually drive the
/// PairingManager. Previously the view created a fresh model whose callbacks
/// were never assigned, leaving the buttons silent no-ops.
public struct FirstLaunchPairingView: View {
    @Environment(AppEnvironment.self) private var environment

    public init() {}

    private var model: OnboardingViewModel { environment.onboardingViewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            Divider()
            content
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 460)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .resizable()
                .frame(width: 36, height: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Welcome to ClaudeSync")
                        .font(.title2).bold()
                    Text(MenuBarRootView.appVersionString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("Sync your AI coding tool environments between two Macs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:                       welcomeStep
        case .remoteLogin(let outcome):      remoteLoginStep(outcome: outcome)
        case .fullDiskAccess(let status):    fdaStep(status: status)
        case .discovery:                     discoveryStep
        case .pairingCode(let state):        pairingCodeStep(state: state)
        case .done:                          doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ClaudeSync needs a few permissions to keep your two Macs in sync.")
                .font(.body)
            stepBullets([
                "Verify Remote Login (SSH) is enabled on this Mac.",
                "Grant Full Disk Access so file changes can be detected.",
                "Pair this Mac with the other one over your local network.",
            ])
            HStack {
                Spacer()
                Button("Continue") { model.advanceFromWelcome() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func remoteLoginStep(outcome: RemoteLoginPreflight.Outcome?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 1 of 3 — Remote Login")
                .font(.headline)
            Text("ClaudeSync uses SSH to transfer files between your Macs. macOS calls this 'Remote Login' and it must be enabled in System Settings → General → Sharing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let outcome {
                if outcome.isReady {
                    statusRow(systemImage: "checkmark.circle.fill", color: .green,
                              text: "Remote Login is enabled.")
                } else {
                    let message = outcome.failingSide?.userFacingMessage
                        ?? "Remote Login appears disabled."
                    statusRow(systemImage: "xmark.octagon.fill", color: .red,
                              text: message)
                    Button("Open System Settings") { model.openSystemSettingsForRemoteLogin() }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("Tap 'Check now' to test SSH connectivity to this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Check now") {
                    Task { await model.runRemoteLoginCheck() }
                }
                .buttonStyle(.bordered)

                let canAdvance: Bool = {
                    if case .remoteLogin(let o?) = model.step { return o.isReady }
                    return false
                }()
                Button("Continue") { model.advanceFromRemoteLogin() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                    .opacity(canAdvance ? 1.0 : 0.5)
                    .help(canAdvance
                          ? "Proceed to Full Disk Access"
                          : "Enable Remote Login first, then click Check now")
            }
        }
    }

    private func fdaStep(status: FullDiskAccessChecker.Status?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 2 of 3 — Full Disk Access")
                .font(.headline)
            Text("ClaudeSync watches your ~/.claude/ and ~/Library/Application Support/Claude/ folders for changes. macOS requires Full Disk Access to monitor those locations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let status {
                switch status {
                case .granted:
                    statusRow(systemImage: "checkmark.circle.fill", color: .green,
                              text: "Full Disk Access is granted.")
                case .denied:
                    statusRow(systemImage: "xmark.octagon.fill", color: .red,
                              text: "Full Disk Access is not granted.")
                    Button("Open System Settings") { model.openSystemSettingsForFullDiskAccess() }
                        .buttonStyle(.bordered)
                case .indeterminate(let reason):
                    statusRow(systemImage: "questionmark.circle.fill", color: .orange,
                              text: "Could not verify automatically (\(reason)). You can continue and grant access later if needed.")
                }
            } else {
                Text("Tap 'Check now' to verify.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Check now") { model.runFullDiskAccessCheck() }
                    .buttonStyle(.bordered)
                Button("Continue") { model.advanceFromFullDiskAccess() }
                    .buttonStyle(.borderedProminent)
                    .disabled({
                        if case .fullDiskAccess(let s?) = model.step {
                            if case .denied = s { return true }
                            return false
                        }
                        return true
                    }())
            }
        }
    }

    private var discoveryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 3 of 3 — Find the other Mac")
                .font(.headline)
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Searching for another ClaudeSync instance on your local network…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // v1.0.1: show discovered peers + Pair buttons inline so the user
            // doesn't have to close this window and dig into the menu bar.
            if !environment.discoveredPeers.isEmpty {
                Divider()
                Text("Discovered peers:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(environment.discoveredPeers) { peer in
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.tint)
                        Text("\(peer.hostname) (\(peer.username))")
                            .font(.callout)
                        Spacer()
                        Button("Pair") {
                            Task { try? await environment.initiatePairing(with: peer) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Text("Make sure the other Mac is awake, on the same WiFi, and running ClaudeSync. If it still doesn't appear, check that the macOS firewall allows ClaudeSync and the Local Network permission is on — on both Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Firewall Settings") { model.openSystemSettingsForFirewall() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Open Local Network Settings") { model.openSystemSettingsForLocalNetwork() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Skip for now") { model.reset() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func pairingCodeStep(state: PairingManager.State) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 3 of 3 — Confirm pairing code")
                .font(.headline)

            switch state {
            case .receivedPairRequest(_, let code):
                pairingCodeBox(code: code,
                               primaryLabel: "Accept — code matches",
                               primaryAction: { await model.acceptPair() })
            case .receivedPairAccept(_, let code):
                pairingCodeBox(code: code,
                               primaryLabel: "Confirm — code matches",
                               primaryAction: { await model.confirmPair() })
            case .sentPairAccept(_, let code):
                pairingCodeBox(code: code,
                               primaryLabel: "Waiting for the other Mac…",
                               primaryAction: nil)
            case .completed:
                statusRow(systemImage: "checkmark.seal.fill", color: .green,
                          text: "Pairing complete.")
            case .rejected(let reason):
                statusRow(systemImage: "xmark.octagon.fill", color: .red,
                          text: "Pairing rejected: \(reason)")
                pairingRetryRow
            case .failed(let message):
                statusRow(systemImage: "exclamationmark.triangle.fill", color: .orange,
                          text: "Pairing failed: \(message)")
                networkTroubleshooting
                pairingRetryRow
            default:
                ProgressView("Waiting for the other Mac…")
            }
        }
    }

    /// Shown under a pairing failure. The #1 cause of "connection to peer
    /// lost" on a LAN is the macOS application firewall RST'ing the inbound
    /// connection, or Local Network permission never having been granted —
    /// both one click away from here. (Either Mac can be the culprit.)
    private var networkTroubleshooting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If both Macs are on the same Wi-Fi, the usual cause is the macOS firewall blocking ClaudeSync, or the Local Network permission being off — on either Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Firewall Settings") { model.openSystemSettingsForFirewall() }
                    .buttonStyle(.bordered)
                Button("Open Local Network Settings") { model.openSystemSettingsForLocalNetwork() }
                    .buttonStyle(.bordered)
            }
            Text("In Firewall → Options: allow incoming connections for ClaudeSync, and turn off “Block all incoming connections” / stealth mode. Then click “Try pairing again”. Do the same on the other Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }

    private var pairingRetryRow: some View {
        HStack {
            Spacer()
            Button("Try pairing again") { model.retryPairing() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow(systemImage: "checkmark.seal.fill", color: .green,
                      text: "Both Macs are paired and syncing.")
            Text("You can close this window. ClaudeSync will continue running in the menu bar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building blocks

    private func stepBullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 6))
                        .padding(.top, 6)
                    Text(item).font(.subheadline)
                }
            }
        }
    }

    private func statusRow(systemImage: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(.subheadline)
        }
    }

    @ViewBuilder
    private func pairingCodeBox(
        code: String,
        primaryLabel: String,
        primaryAction: (() async -> Void)?
    ) -> some View {
        Text("Verify that this code matches what's shown on the other Mac:")
            .font(.subheadline)
        Text(code)
            .font(.system(size: 44, weight: .bold, design: .monospaced))
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(12)
        HStack {
            if let primaryAction {
                Button(primaryLabel) {
                    Task { await primaryAction() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView(primaryLabel)
            }
            Button("Codes don't match — cancel") {
                Task { await model.rejectPair(reason: "code-mismatch") }
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview("Welcome") {
    FirstLaunchPairingView()
        .environment(AppEnvironment())
}
