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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: environment.overallStatus.systemImageName)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ClaudeSync")
                    .font(.headline)
                Text(environment.overallStatus.shortLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

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
            Button("Open Onboarding") {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Quit ClaudeSync") {
                Task {
                    await environment.shutdownSyncEngine()
                    NSApp.terminate(nil)
                }
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

#Preview {
    MenuBarRootView()
        .environment(AppEnvironment())
}
