import SwiftUI

/// Root content for the MenuBarExtra popover.
///
/// Phase 1 shows a minimal status surface: connection summary, a quit button,
/// and a placeholder for the per-target rows that arrive in later phases.
struct MenuBarRootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: environment.overallStatus.systemImageName)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ClaudeSync")
                    .font(.headline)
                Text("Phase 1 — menu bar shell")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(environment.overallStatus.shortLabel)
                .font(.body)
        }
    }

    @Environment(\.openWindow) private var openWindow

    private var footer: some View {
        HStack {
            Button("Open Onboarding") {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Quit ClaudeSync") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

#Preview {
    MenuBarRootView()
        .environment(AppEnvironment())
}
