import SwiftUI

@main
struct ClaudeSyncApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(environment)
        } label: {
            Label("ClaudeSync", systemImage: environment.overallStatus.systemImageName)
        }
        .menuBarExtraStyle(.window)
    }
}
