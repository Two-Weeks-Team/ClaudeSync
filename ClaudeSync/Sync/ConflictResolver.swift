import Foundation
import CryptoKit

/// Resolves the case where the SAME relative path was modified on BOTH the
/// local and remote machines since the last successful sync.
///
/// Phase 5 standard scope (per user choice):
///
/// 1. **Identical contents** (hash match) → no real conflict, just touch
///    timestamps, no archive.
/// 2. **JSON / YAML files** → structural merge: parse both, deep-merge
///    objects (newer-mtime wins on key-level conflicts), write merged file
///    in place. If parsing fails on either side, fall back to newer-wins.
/// 3. **Same-timestamp tie** on a non-JSON file → keep BOTH copies with
///    `.machine-A` / `.machine-B` suffixes; user must rename the keeper.
/// 4. **Default (newer-wins)** → file with later `mtime` wins; the loser is
///    archived to `~/.claudesync/conflicts/YYYY-MM-DD/<relativePath>` so the
///    overwrite is recoverable.
///
/// Reference: PRD FR-09, TECHNICAL_SPEC §7 (Conflict Resolution).
public actor ConflictResolver {

    public enum Strategy: String, Codable, Sendable {
        case newerWins
        case largerWins
        case mergeJSON
        case keepBoth
        case manual
    }

    public enum Winner: Sendable, Equatable {
        case local
        case remote
        case mergedInPlace          // wrote a merge result back to local path
        case bothPreserved          // wrote `.machine-A`/`.machine-B` suffixes
        case identical              // no actual conflict, contents match
    }

    public struct Resolution: Sendable, Equatable {
        public let relativePath: String
        public let winner: Winner
        public let backupPath: String?  // archived loser (nil for identical/merged/bothPreserved)
        public let strategy: Strategy
    }

    public struct Inputs: Sendable {
        public let relativePath: String
        public let localPath: URL
        public let remotePath: URL
        public let localModTime: Date
        public let remoteModTime: Date

        public init(relativePath: String, localPath: URL, remotePath: URL,
                    localModTime: Date, remoteModTime: Date) {
            self.relativePath = relativePath
            self.localPath = localPath
            self.remotePath = remotePath
            self.localModTime = localModTime
            self.remoteModTime = remoteModTime
        }
    }

    public let archiveBaseDirectory: URL
    private let dateFormatter: DateFormatter

    public init(archiveBaseDirectory: URL? = nil) {
        let base = archiveBaseDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/conflicts", isDirectory: true)
        self.archiveBaseDirectory = base
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = f
    }

    // MARK: - Strategy selection

    public nonisolated func strategyFor(path: String, userPreference: Strategy?) -> Strategy {
        if let userPreference { return userPreference }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "json", "yaml", "yml": return .mergeJSON
        case "png", "jpg", "jpeg", "pdf", "zip", "tar", "gz", "mp4", "mov":
            return .largerWins
        default: return .newerWins
        }
    }

    // MARK: - Resolve

    public func resolve(_ inputs: Inputs, strategy: Strategy? = nil) async throws -> Resolution {
        let s = strategy ?? strategyFor(path: inputs.relativePath, userPreference: nil)

        // Short-circuit: identical contents → no real conflict.
        if try identicalContents(local: inputs.localPath, remote: inputs.remotePath) {
            return Resolution(relativePath: inputs.relativePath,
                              winner: .identical, backupPath: nil, strategy: s)
        }

        // Same-mtime tie (within 1 second) on non-merge strategy → preserve both.
        if abs(inputs.localModTime.timeIntervalSince(inputs.remoteModTime)) < 1.0 && s != .mergeJSON {
            return try preserveBoth(inputs: inputs, strategy: s)
        }

        switch s {
        case .mergeJSON:
            return try mergeJSON(inputs: inputs)
        case .largerWins:
            return try resolveLargerWins(inputs: inputs)
        case .newerWins, .manual:
            return try resolveNewerWins(inputs: inputs, strategy: s)
        case .keepBoth:
            return try preserveBoth(inputs: inputs, strategy: s)
        }
    }

    // MARK: - Strategies

    private func resolveNewerWins(inputs: Inputs, strategy: Strategy) throws -> Resolution {
        let localNewer = inputs.localModTime > inputs.remoteModTime
        let backup = try archive(
            sourceURL: localNewer ? inputs.remotePath : inputs.localPath,
            relativePath: inputs.relativePath,
            machineLabel: localNewer ? "remote" : "local"
        )
        if localNewer {
            // Local wins → overwrite remote-staged file with local content.
            try replaceFile(at: inputs.remotePath, with: inputs.localPath)
        } else {
            // Remote wins → overwrite local file with remote-staged content.
            try replaceFile(at: inputs.localPath, with: inputs.remotePath)
        }
        return Resolution(
            relativePath: inputs.relativePath,
            winner: localNewer ? .local : .remote,
            backupPath: backup.path,
            strategy: strategy
        )
    }

    private func resolveLargerWins(inputs: Inputs) throws -> Resolution {
        let localSize = try sizeOf(inputs.localPath)
        let remoteSize = try sizeOf(inputs.remotePath)
        let localWins = localSize >= remoteSize
        let backup = try archive(
            sourceURL: localWins ? inputs.remotePath : inputs.localPath,
            relativePath: inputs.relativePath,
            machineLabel: localWins ? "remote" : "local"
        )
        if localWins {
            try replaceFile(at: inputs.remotePath, with: inputs.localPath)
        } else {
            try replaceFile(at: inputs.localPath, with: inputs.remotePath)
        }
        return Resolution(
            relativePath: inputs.relativePath,
            winner: localWins ? .local : .remote,
            backupPath: backup.path,
            strategy: .largerWins
        )
    }

    private func mergeJSON(inputs: Inputs) throws -> Resolution {
        guard let local = try parseJSON(inputs.localPath),
              let remote = try parseJSON(inputs.remotePath) else {
            // Fall back to newer-wins when either side is unparseable.
            return try resolveNewerWins(inputs: inputs, strategy: .mergeJSON)
        }
        let localNewer = inputs.localModTime >= inputs.remoteModTime
        let merged = Self.deepMerge(local: local, remote: remote, preferLocal: localNewer)
        let data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: inputs.localPath, options: .atomic)
        try data.write(to: inputs.remotePath, options: .atomic)
        return Resolution(
            relativePath: inputs.relativePath,
            winner: .mergedInPlace,
            backupPath: nil,
            strategy: .mergeJSON
        )
    }

    private func preserveBoth(inputs: Inputs, strategy: Strategy) throws -> Resolution {
        let localCopy = inputs.localPath.deletingLastPathComponent()
            .appendingPathComponent(inputs.localPath.lastPathComponent + ".machine-A")
        let remoteCopy = inputs.localPath.deletingLastPathComponent()
            .appendingPathComponent(inputs.localPath.lastPathComponent + ".machine-B")
        try? FileManager.default.removeItem(at: localCopy)
        try? FileManager.default.removeItem(at: remoteCopy)
        try FileManager.default.copyItem(at: inputs.localPath,  to: localCopy)
        try FileManager.default.copyItem(at: inputs.remotePath, to: remoteCopy)
        return Resolution(
            relativePath: inputs.relativePath,
            winner: .bothPreserved,
            backupPath: nil,
            strategy: strategy
        )
    }

    // MARK: - Archive / IO helpers

    /// Copy `sourceURL` into `~/.claudesync/conflicts/YYYY-MM-DD/<relPath>.<label>`.
    /// Returns the archive URL.
    @discardableResult
    func archive(sourceURL: URL, relativePath: String, machineLabel: String) throws -> URL {
        let dateDir = archiveBaseDirectory
            .appendingPathComponent(dateFormatter.string(from: Date()), isDirectory: true)
        let target = dateDir.appendingPathComponent("\(relativePath).\(machineLabel)")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: sourceURL, to: target)
        return target
    }

    /// Purge archive entries older than `daysOld`. Default 30 days per
    /// PRD FR-09 retention policy.
    public func purgeOlderThan(days: Int = 30) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveBaseDirectory.path) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let dateDirs = try fm.contentsOfDirectory(at: archiveBaseDirectory,
                                                  includingPropertiesForKeys: nil)
        for dir in dateDirs {
            if let attrs = try? fm.attributesOfItem(atPath: dir.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff {
                try fm.removeItem(at: dir)
            }
        }
    }

    private func identicalContents(local: URL, remote: URL) throws -> Bool {
        let a = try Data(contentsOf: local)
        let b = try Data(contentsOf: remote)
        return SHA256.hash(data: a) == SHA256.hash(data: b)
    }

    private func sizeOf(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return Int64((attrs[.size] as? NSNumber)?.intValue ?? 0)
    }

    private func parseJSON(_ url: URL) throws -> [String: Any]? {
        let data = try Data(contentsOf: url)
        // Tolerate malformed JSON — caller treats nil as "fall back to newer-wins".
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return obj as? [String: Any]
    }

    private func replaceFile(at destination: URL, with source: URL) throws {
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - JSON deep merge (static — pure)

    /// Recursively merge two JSON dictionaries. On key collisions:
    ///   * if both values are `[String: Any]` → recurse,
    ///   * otherwise the side specified by `preferLocal` wins.
    static func deepMerge(local: [String: Any], remote: [String: Any], preferLocal: Bool) -> [String: Any] {
        var merged = preferLocal ? remote : local
        let overlay = preferLocal ? local : remote
        for (key, overlayValue) in overlay {
            if let existing = merged[key] as? [String: Any],
               let overlayDict = overlayValue as? [String: Any] {
                merged[key] = deepMerge(local: overlayDict, remote: existing, preferLocal: true)
            } else {
                merged[key] = overlayValue
            }
        }
        return merged
    }
}
