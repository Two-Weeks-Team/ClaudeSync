import Foundation

/// Persistent rolling log of the last 100 sync events.
///
/// Stored as a JSON array at `~/.claudesync/history.json` so the UI History
/// tab can show what synced after a restart. We keep this lightweight — no
/// SQLite — because at most 100 records totalling ~50 KB.
public actor SyncHistory {

    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let target: SyncTarget
        public let direction: SyncDirection
        public let status: StatusCode
        public let filesTransferred: Int
        public let bytesTransferred: Int64
        public let durationSeconds: Double
        public let stderr: String

        public enum StatusCode: String, Codable, Sendable {
            case success
            case partialSuccess
            case failure
            case cancelled
        }

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            target: SyncTarget,
            direction: SyncDirection,
            status: StatusCode,
            filesTransferred: Int = 0,
            bytesTransferred: Int64 = 0,
            durationSeconds: Double = 0,
            stderr: String = ""
        ) {
            self.id = id
            self.timestamp = timestamp
            self.target = target
            self.direction = direction
            self.status = status
            self.filesTransferred = filesTransferred
            self.bytesTransferred = bytesTransferred
            self.durationSeconds = durationSeconds
            self.stderr = stderr
        }
    }

    public let storeURL: URL
    public let maxEntries: Int

    private var entries: [Entry] = []
    private var loaded = false

    public init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        maxEntries: Int = 100
    ) {
        self.storeURL = homeDirectory.appendingPathComponent(".claudesync/history.json")
        self.maxEntries = maxEntries
    }

    public func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder.iso8601.decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    public func record(_ result: SyncResult, direction: SyncDirection) async {
        await loadIfNeeded()
        let status: Entry.StatusCode = {
            switch result.status {
            case .success:        return .success
            case .partialSuccess: return .partialSuccess
            case .failure:        return .failure
            case .cancelled:      return .cancelled
            }
        }()
        let entry = Entry(
            target: result.target,
            direction: direction,
            status: status,
            filesTransferred: result.filesTransferred,
            bytesTransferred: result.bytesTransferred,
            durationSeconds: result.duration.seconds,
            stderr: result.stderr
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        await persist()
    }

    public func recent(limit: Int = 100) async -> [Entry] {
        await loadIfNeeded()
        return Array(entries.prefix(limit))
    }

    public func clear() async {
        entries.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func persist() async {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder.iso8601.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - Coders

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension Duration {
    var seconds: Double {
        let comps = components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
