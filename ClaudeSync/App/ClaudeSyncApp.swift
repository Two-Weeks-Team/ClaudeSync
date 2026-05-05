import SwiftUI

@main
struct ClaudeSyncApp: App {
    @State private var environment = AppEnvironment()
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
    }
}
