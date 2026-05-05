import SwiftUI

/// First-launch onboarding window — guides the user through preflight checks
/// and the initial pairing handshake.
///
/// Shown via a `WindowGroup` scene routed by `AppEnvironment.needsOnboarding`.
public struct FirstLaunchPairingView: View {
    @State private var model: OnboardingViewModel

    public init(model: OnboardingViewModel = OnboardingViewModel()) {
        _model = State(initialValue: model)
    }

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
                Text("Welcome to ClaudeSync")
                    .font(.title2).bold()
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
                    let detail = String(describing: outcome.failingSide ?? .local(.connectionRefused(port: 22)))
                    statusRow(systemImage: "xmark.octagon.fill", color: .red,
                              text: "Remote Login appears disabled (\(detail)).")
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

                Button("Continue") { model.advanceFromRemoteLogin() }
                    .buttonStyle(.borderedProminent)
                    .disabled({
                        if case .remoteLogin(let o?) = model.step { return !o.isReady }
                        return true
                    }())
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
            Text("Make sure the other Mac is awake, on the same WiFi, and running ClaudeSync.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            case .receivedPairAccept(_, let code), .receivedPairRequest(_, let code), .sentPairAccept(_, let code):
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
                    Button("Codes match — pair") { /* hooked by AppEnvironment */ }
                        .buttonStyle(.borderedProminent)
                    Button("Codes don't match — cancel") { /* hooked by AppEnvironment */ }
                        .buttonStyle(.bordered)
                }
            case .completed:
                statusRow(systemImage: "checkmark.seal.fill", color: .green,
                          text: "Pairing complete.")
            case .rejected(let reason):
                statusRow(systemImage: "xmark.octagon.fill", color: .red,
                          text: "Pairing rejected: \(reason)")
            case .failed(let message):
                statusRow(systemImage: "exclamationmark.triangle.fill", color: .orange,
                          text: "Pairing failed: \(message)")
            default:
                ProgressView("Waiting for the other Mac…")
            }
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
}

#Preview("Welcome") { FirstLaunchPairingView() }
