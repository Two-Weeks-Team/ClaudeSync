import SwiftUI

@main
struct ClaudeSyncApp: App {
    @State private var environment: AppEnvironment

    init() {
        // v1.1: refuse to start a second instance — see SingleInstanceGuard
        // for the failure modes (Bonjour port collision, doubled FSEvents).
        // Must run BEFORE AppEnvironment is constructed since the env init
        // already starts Bonjour advertising.
        SingleInstanceGuard.enforce()
        _environment = State(initialValue: AppEnvironment())
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Hidden anchor window so MenuBarExtra + Settings interplay works
        // correctly per TECH_REFERENCES §1 (the "Settings issues 15.5+" gotcha).
        WindowGroup("Onboarding", id: "onboarding") {
            FirstLaunchPairingView()
                .environment(environment)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarRootView()
                .environment(environment)
        } label: {
            Label("ClaudeSync", systemImage: environment.overallStatus.systemImageName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
