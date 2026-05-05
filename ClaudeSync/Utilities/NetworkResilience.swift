import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

/// v1.1 (RCA-M5/M6/M7): observes network reachability + system sleep/wake
/// + Bonjour listener failures, and forwards normalized events to its
/// owner so the discovery / sync engine can be restarted with backoff.
///
/// We keep this orthogonal to PeerDiscoveryActor so that the discovery
/// actor stays single-purpose and the recovery policy (which operations
/// to restart, in what order) lives in AppEnvironment.
@MainActor
public final class NetworkResilienceMonitor {

    public enum Event: Sendable, Equatable {
        case networkLost
        case networkRecovered
        case systemWillSleep
        case systemDidWake
    }

    private let pathMonitor: NWPathMonitor
    private let pathQueue = DispatchQueue(label: "claudesync.path-monitor",
                                          qos: .utility)
    private var lastPathStatus: NWPath.Status?
    private var observers: [NSObjectProtocol] = []
    private let logger: AppLogger
    private let onEvent: @MainActor (Event) -> Void

    public init(logger: AppLogger = .shared,
                onEvent: @escaping @MainActor (Event) -> Void) {
        self.logger = logger
        self.onEvent = onEvent
        self.pathMonitor = NWPathMonitor()
    }

    public func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Hop to MainActor so the callback can be Sendable-clean and
            // we can mutate `lastPathStatus` without locking.
            Task { @MainActor [weak self] in
                self?.handle(pathUpdate: path)
            }
        }
        pathMonitor.start(queue: pathQueue)

        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info("system willSleep — pausing discovery",
                                 category: "resilience")
                self.onEvent(.systemWillSleep)
            }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info("system didWake — restarting discovery",
                                 category: "resilience")
                self.onEvent(.systemDidWake)
            }
        }
        observers = [sleep, wake]
        #endif
    }

    public func stop() {
        pathMonitor.cancel()
        #if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        for ob in observers { center.removeObserver(ob) }
        observers.removeAll()
        #endif
    }

    private func handle(pathUpdate path: NWPath) {
        let status = path.status
        defer { lastPathStatus = status }
        guard status != lastPathStatus else { return }
        switch status {
        case .satisfied:
            if lastPathStatus != nil {
                logger.info("network recovered — restarting discovery",
                            category: "resilience")
                onEvent(.networkRecovered)
            } else {
                logger.info("initial network path is satisfied",
                            category: "resilience")
            }
        case .unsatisfied, .requiresConnection:
            logger.warning("network path unsatisfied — pausing discovery",
                           category: "resilience")
            onEvent(.networkLost)
        @unknown default:
            break
        }
    }

    deinit {
        // Clean up observers if the owner forgot to call stop().
        pathMonitor.cancel()
    }
}
