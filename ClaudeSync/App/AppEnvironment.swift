import Foundation
import SwiftUI

/// Top-level dependency container shared across the SwiftUI scene tree.
///
/// Phase 1 only wires the logger and an early app-state placeholder so the
/// MenuBarExtra has something concrete to bind to. Subsequent phases will
/// add `SyncCoordinator`, `PeerDiscoveryActor`, etc., behind the same root.
@MainActor
@Observable
final class AppEnvironment {
    let logger: AppLogger

    /// Coarse global status used by the menu bar icon. Real state comes from
    /// `SyncCoordinator` once Phase 3+ wiring lands.
    var overallStatus: OverallStatus = .idle

    init(logger: AppLogger = .shared) {
        self.logger = logger
        logger.info("AppEnvironment initialized", category: "app")
    }

    enum OverallStatus: Equatable {
        case idle           // No peer paired or app just launched.
        case discovering    // Bonjour browsing for a peer.
        case connected      // Peer reachable, no active transfer.
        case syncing        // rsync in progress.
        case error(String)  // Recoverable failure surfaced to the user.

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
            case .connected:      return "Connected"
            case .syncing:        return "Syncing…"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }
}
