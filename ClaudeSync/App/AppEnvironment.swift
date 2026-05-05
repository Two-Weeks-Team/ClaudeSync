import Foundation
import SwiftUI

/// Top-level dependency container for the SwiftUI scene tree. Owns the
/// long-lived actors (FileWatcherActor, FileSyncActor, BatchAccumulator,
/// SyncCoordinator) and exposes their state as published `@Observable`
/// properties for the menu bar UI.
@MainActor
@Observable
final class AppEnvironment {
    let logger: AppLogger

    // MARK: - Long-lived domain actors

    let watcher: FileWatcherActor
    let syncActor: FileSyncActor
    let batchAccumulator: BatchAccumulator
    let conflictResolver: ConflictResolver
    let coordinator: SyncCoordinator
    let sshKeys: SSHKeyManager

    // MARK: - Published UI state

    var overallStatus: OverallStatus = .idle
    var needsOnboarding: Bool = true
    var isAutoStarted: Bool = false

    init(
        logger: AppLogger = .shared,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.logger = logger
        let watcherCfg = FileWatcherActor.Configuration(homeDirectory: homeDirectory)
        let watcher = FileWatcherActor(config: watcherCfg)
        let builder = RsyncCommandBuilder()
        // peer is nil until the user pairs — coordinator can run in
        // "watching only" mode safely.
        let syncActor = FileSyncActor(
            config: .init(builder: builder),
            watcher: watcher,
            peer: nil
        )
        let (_, batch) = BatchAccumulator.makeStream(flushInterval: .seconds(300))
        let resolver = ConflictResolver()

        self.watcher = watcher
        self.syncActor = syncActor
        self.batchAccumulator = batch
        self.conflictResolver = resolver
        self.coordinator = SyncCoordinator(
            watcher: watcher,
            syncActor: syncActor,
            batchAccumulator: batch,
            conflictResolver: resolver
        )
        self.sshKeys = SSHKeyManager(homeDirectoryURL: homeDirectory)

        logger.info("AppEnvironment initialized", category: "app")
    }

    /// Boot the watcher + coordinator. Safe to call multiple times — internal
    /// guards prevent double-start.
    func bootSyncEngine() async {
        guard !isAutoStarted else { return }
        isAutoStarted = true
        logger.info("Booting sync engine", category: "app")
        await coordinator.start(targets: [.claudeConfig, .claudeAppSupport, .codexConfig])
        overallStatus = .connected   // optimistic: refines once peer wiring lands
    }

    func shutdownSyncEngine() async {
        guard isAutoStarted else { return }
        await coordinator.stop()
        isAutoStarted = false
        overallStatus = .idle
    }

    enum OverallStatus: Equatable {
        case idle
        case discovering
        case connected
        case syncing
        case error(String)

        var systemImageName: String {
            switch self {
            case .idle:        return "circle.dashed"
            case .discovering: return "antenna.radiowaves.left.and.right"
            case .connected:   return "checkmark.circle"
            case .syncing:     return "arrow.triangle.2.circlepath"
            case .error:       return "exclamationmark.triangle"
            }
        }

        var shortLabel: String {
            switch self {
            case .idle:           return "Idle"
            case .discovering:    return "Searching for peer…"
            case .connected:      return "Watching"
            case .syncing:        return "Syncing…"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }
}
