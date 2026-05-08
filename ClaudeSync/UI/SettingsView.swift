import SwiftUI

/// SwiftUI Settings scene content. Bound to `AppEnvironment.currentPreferences`
/// via local @State copy so the user can edit several fields and apply once.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var draft: Preferences = .default
    @State private var newPattern: String = ""
    @State private var selectedTarget: SyncTarget = .claudeConfig
    @State private var saveStatus: SaveStatus = .idle

    private enum SaveStatus: Equatable {
        case idle
        case saving
        case saved
        case launchFailed
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            networkTab
                .tabItem { Label("Network", systemImage: "network") }
            excludesTab
                .tabItem { Label("Excludes", systemImage: "nosign") }
        }
        .frame(width: 520, height: 380)
        .padding(20)
        .onAppear { draft = environment.currentPreferences }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch ClaudeSync at login", isOn: $draft.launchAtLogin)
                Text("Uses macOS Login Items. You can revoke this anytime in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Auto-pair Macs signed into the same Apple ID",
                       isOn: $draft.autoPairSameAppleID)
                Text("Uses iCloud Keychain (end-to-end encrypted) to share a pairing fingerprint between your Macs. When matched, the 6-digit visual code is skipped — the Apple ID itself is the auth factor. Requires iCloud Keychain enabled on both Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Launch status") {
                    Text(launchStatusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // v1.0.1: surface the persisted paired peer + a Forget button so
            // the user can sever the link without deleting authorized_keys
            // by hand.
            Section("Paired peer") {
                if let p = environment.activePairedPeer {
                    LabeledContent("Hostname") {
                        Text(p.hostname).font(.caption)
                    }
                    LabeledContent("Username") {
                        Text(p.username).font(.caption)
                    }
                    LabeledContent("Fingerprint") {
                        Text(p.publicKeyFingerprint).font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("Forget paired peer") {
                        Task { await environment.forgetPairedPeer() }
                    }
                    .foregroundStyle(.red)
                } else {
                    Text("No peer paired yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            saveBar
        }
    }

    private var launchStatusLabel: String {
        switch environment.launchAtLogin.status {
        case .enabled:           return "Registered"
        case .disabled:          return "Not registered"
        case .requiresApproval:  return "Awaiting user approval in System Settings"
        case .notSupported:      return "Requires macOS 13+"
        }
    }

    // MARK: - Network

    private var networkTab: some View {
        Form {
            Section("Bandwidth") {
                Stepper(value: $draft.bandwidthLimitKBps, in: 0...1_000_000, step: 256) {
                    if draft.bandwidthLimitKBps == 0 {
                        Text("Unlimited")
                    } else {
                        Text("\(draft.bandwidthLimitKBps) KiB/s")
                    }
                }
                Text("Passed to rsync as --bwlimit. 0 disables the cap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            saveBar
        }
    }

    // MARK: - Excludes

    private var excludesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Target", selection: $selectedTarget) {
                ForEach(SyncTarget.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)

            Text("Built-in excludes for this target:")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(selectedTarget.spec.excludePatterns, id: \.self) { p in
                        Text("• \(p)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 70)

            Divider()

            Text("Your additional patterns")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. *.log", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addPattern() }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(currentExtras, id: \.self) { p in
                    HStack {
                        Text(p).font(.caption)
                        Spacer()
                        Button {
                            removePattern(p)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(maxHeight: 100)

            saveBar
        }
    }

    private var currentExtras: [String] {
        draft.extraExcludes[selectedTarget.rawValue] ?? []
    }

    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var arr = draft.extraExcludes[selectedTarget.rawValue] ?? []
        guard !arr.contains(trimmed) else { return }
        arr.append(trimmed)
        draft.extraExcludes[selectedTarget.rawValue] = arr
        newPattern = ""
    }

    private func removePattern(_ pattern: String) {
        guard var arr = draft.extraExcludes[selectedTarget.rawValue] else { return }
        arr.removeAll { $0 == pattern }
        if arr.isEmpty {
            draft.extraExcludes.removeValue(forKey: selectedTarget.rawValue)
        } else {
            draft.extraExcludes[selectedTarget.rawValue] = arr
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack {
            switch saveStatus {
            case .idle:          EmptyView()
            case .saving:        ProgressView().controlSize(.small)
            case .saved:         Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green).font(.caption)
            case .launchFailed:  Label("Login item registration failed",
                                       systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.caption)
            }
            Spacer()
            Button("Revert") {
                draft = environment.currentPreferences
            }
            Button("Apply") { Task { await apply() } }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == environment.currentPreferences)
        }
        .padding(.top, 8)
    }

    private func apply() async {
        saveStatus = .saving
        await environment.applyPreferences(draft)
        if draft.launchAtLogin && environment.launchAtLogin.status != .enabled {
            saveStatus = .launchFailed
        } else {
            saveStatus = .saved
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppEnvironment())
}
