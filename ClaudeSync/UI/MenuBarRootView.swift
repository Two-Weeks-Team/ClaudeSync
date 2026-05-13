import SwiftUI

/// Root content for the MenuBarExtra popover. Phase 6 expands the Phase 1
/// stub with per-target rows, recent activity, and Start/Stop control.
struct MenuBarRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusRow
            if let reason = environment.tlsDegradedReason {
                tlsWarningBanner(reason: reason)
            }
            // RCA-C2: surface incoming/in-flight pairing in the menu bar so
            // the responder Mac can confirm without opening the onboarding
            // window. Before v1.0.1, only the onboarding window had this UI
            // so a Mac that received a pairRequest had no way to confirm.
            if pairingBannerVisible {
                Divider()
                pairingBanner
            }
            Divider()
            peersSection
            Divider()
            targetsSection
            if !environment.coordinator.recentResults.isEmpty {
                Divider()
                recentActivitySection
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .task {
            // Auto-boot the watcher when the popover first appears so the user
            // sees something happening even before pairing completes.
            await environment.bootSyncEngine()
        }
    }

    // MARK: - Pairing banner (RCA-C2)

    private var pairingBannerVisible: Bool {
        switch environment.activePairingState {
        case .receivedPairRequest, .receivedPairAccept, .sentPairAccept,
             .sentPairRequest, .failed, .rejected:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var pairingBanner: some View {
        switch environment.activePairingState {
        case .receivedPairRequest(let req, let code):
            pairingPrompt(
                title: "Pair request from \(req.hostname)",
                code: code,
                primary: "Accept — codes match",
                primaryAction: { await environment.acceptPendingPairing() }
            )
        case .receivedPairAccept(let accept, let code):
            pairingPrompt(
                title: "\(accept.hostname) accepted — confirm code",
                code: code,
                primary: "Confirm — codes match",
                primaryAction: { await environment.confirmPairingCode() }
            )
        case .sentPairAccept(_, let code):
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for the other Mac to confirm…")
                    .font(.caption).foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
            }
        case .sentPairRequest:
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for peer to accept…").font(.caption)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Pairing failed: \(msg)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Text("Usual cause on a LAN: the macOS firewall blocking ClaudeSync, or Local Network permission off — on either Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Firewall Settings") {
                        environment.onboardingViewModel.openSystemSettingsForFirewall()
                    }.buttonStyle(.bordered).controlSize(.small)
                    Button("Local Network") {
                        environment.onboardingViewModel.openSystemSettingsForLocalNetwork()
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        case .rejected(let reason):
            Label("Pairing rejected: \(reason)", systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func pairingPrompt(
        title: String, code: String, primary: String,
        primaryAction: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            HStack {
                Button(primary) { Task { await primaryAction() } }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    Task { await environment.rejectActivePairing(reason: "user-cancelled") }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: environment.overallStatus.systemImageName)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("ClaudeSync")
                        .font(.headline)
                    Text(Self.appVersionString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(environment.overallStatus.shortLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// "v1.2.8 (12)" — short version + build, read from the bundle Info.plist.
    static let appVersionString: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }()

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coordinator")
                .font(.caption).foregroundStyle(.secondary)
            Text(coordinatorStateLabel)
                .font(.body)
        }
    }

    private var coordinatorStateLabel: String {
        switch environment.coordinator.state {
        case .idle:                  return "Idle"
        case .watching:              return "Watching for changes"
        case .syncing(let active):   return "Syncing \(active) job(s)…"
        case .error(let message):    return "Error: \(message)"
        }
    }

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Peers on this network")
                .font(.caption).foregroundStyle(.secondary)
            if environment.discoveredPeers.isEmpty {
                Text("No peers discovered yet")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(environment.discoveredPeers) { peer in
                    HStack(spacing: 6) {
                        Image(systemName: peer.isPaired ? "checkmark.shield.fill" : "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(peer.isPaired ? .green : .blue)
                        Text("\(peer.hostname) (\(peer.username))")
                            .font(.caption)
                        Spacer()
                        if environment.activePairedPeer?.machineId == peer.machineId {
                            Label("Paired", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Button("Pair") {
                                Task { try? await environment.initiatePairing(with: peer) }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Targets")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(SyncTarget.allCases) { target in
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(target.displayName).font(.callout)
                    Spacer()
                    if let lastSync = environment.coordinator.lastSyncTimes[target] {
                        Text(lastSync.formatted(.relative(presentation: .numeric)))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("—").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await environment.coordinator.triggerFullSync(target) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Force sync \(target.displayName)")
                }
            }
        }
    }

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Activity")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(environment.coordinator.recentResults.prefix(5).enumerated()),
                    id: \.offset) { _, status in
                HStack(spacing: 6) {
                    Image(systemName: statusIcon(status))
                        .font(.caption)
                        .foregroundStyle(statusColor(status))
                    Text(statusText(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func statusIcon(_ s: SyncResult.ResultStatus) -> String {
        switch s {
        case .success:                return "checkmark.circle.fill"
        case .partialSuccess:         return "exclamationmark.circle.fill"
        case .failure:                return "xmark.octagon.fill"
        case .cancelled:              return "minus.circle.fill"
        }
    }

    private func statusColor(_ s: SyncResult.ResultStatus) -> Color {
        switch s {
        case .success:                return .green
        case .partialSuccess:         return .yellow
        case .failure:                return .red
        case .cancelled:              return .gray
        }
    }

    private func statusText(_ s: SyncResult.ResultStatus) -> String {
        switch s {
        case .success:                                    return "Synced successfully"
        case .partialSuccess(let ok, let fail):           return "Partial: \(ok) ok, \(fail) failed"
        case .failure(let reason):                        return "Failed: \(reason)"
        case .cancelled:                                  return "Cancelled"
        }
    }

    private var footer: some View {
        HStack {
            Button("Onboarding") {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)
            Button("Settings…") {
                openSettings()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(",", modifiers: [.command])
            Spacer()
            Button("Quit") {
                Task {
                    await environment.shutdownSyncEngine()
                    NSApp.terminate(nil)
                }
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    @ViewBuilder
    private func tlsWarningBanner(reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Control channel is plaintext")
                    .font(.caption).bold()
                Text("openssl missing — visual code + nonce + known_hosts still authenticate the peer. Install via `brew install openssl` and restart for TLS.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

#Preview {
    MenuBarRootView()
        .environment(AppEnvironment())
}
