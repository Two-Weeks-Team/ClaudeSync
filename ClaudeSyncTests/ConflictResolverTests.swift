import XCTest
@testable import ClaudeSync

final class ConflictResolverTests: XCTestCase {
    var tempDir: URL!
    var archiveDir: URL!
    var resolver: ConflictResolver!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        archiveDir = tempDir.appendingPathComponent("conflicts", isDirectory: true)
        resolver = ConflictResolver(archiveBaseDirectory: archiveDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Strategy selection

    func testStrategy_jsonReturnsMerge() {
        XCTAssertEqual(resolver.strategyFor(path: "settings.json", userPreference: nil), .mergeJSON)
        XCTAssertEqual(resolver.strategyFor(path: "config.yaml", userPreference: nil), .mergeJSON)
    }

    func testStrategy_imageReturnsLargerWins() {
        XCTAssertEqual(resolver.strategyFor(path: "icon.png", userPreference: nil), .largerWins)
        XCTAssertEqual(resolver.strategyFor(path: "video.mp4", userPreference: nil), .largerWins)
    }

    func testStrategy_unknownReturnsNewerWins() {
        XCTAssertEqual(resolver.strategyFor(path: "data.bin", userPreference: nil), .newerWins)
    }

    func testStrategy_userPreferenceOverrides() {
        XCTAssertEqual(resolver.strategyFor(path: "x.json", userPreference: .keepBoth), .keepBoth)
    }

    // MARK: - Identical contents

    func testIdenticalFiles_returnIdentical_withoutArchive() async throws {
        let local = tempDir.appendingPathComponent("local.txt")
        let remote = tempDir.appendingPathComponent("remote.txt")
        try "same".write(to: local, atomically: true, encoding: .utf8)
        try "same".write(to: remote, atomically: true, encoding: .utf8)

        let res = try await resolver.resolve(.init(
            relativePath: "x.txt", localPath: local, remotePath: remote,
            localModTime: Date(), remoteModTime: Date().addingTimeInterval(60)
        ), strategy: .newerWins)

        XCTAssertEqual(res.winner, .identical)
        XCTAssertNil(res.backupPath)
    }

    // MARK: - Newer wins

    func testNewerWins_localNewer_localContentsReplaceRemote_andRemoteIsArchived() async throws {
        let local = tempDir.appendingPathComponent("local.txt")
        let remote = tempDir.appendingPathComponent("remote.txt")
        try "LOCAL CONTENT".write(to: local, atomically: true, encoding: .utf8)
        try "REMOTE CONTENT".write(to: remote, atomically: true, encoding: .utf8)

        let res = try await resolver.resolve(.init(
            relativePath: "test.txt", localPath: local, remotePath: remote,
            localModTime: Date(),
            remoteModTime: Date().addingTimeInterval(-3600)
        ), strategy: .newerWins)

        XCTAssertEqual(res.winner, .local)
        XCTAssertNotNil(res.backupPath)

        let remoteContents = try String(contentsOf: remote, encoding: .utf8)
        XCTAssertEqual(remoteContents, "LOCAL CONTENT")

        let archived = try String(contentsOfFile: res.backupPath!, encoding: .utf8)
        XCTAssertEqual(archived, "REMOTE CONTENT")
    }

    func testNewerWins_remoteNewer_remoteReplacesLocal_andLocalIsArchived() async throws {
        let local = tempDir.appendingPathComponent("a.txt")
        let remote = tempDir.appendingPathComponent("b.txt")
        try "OLD".write(to: local, atomically: true, encoding: .utf8)
        try "NEW".write(to: remote, atomically: true, encoding: .utf8)

        let res = try await resolver.resolve(.init(
            relativePath: "a.txt", localPath: local, remotePath: remote,
            localModTime: Date().addingTimeInterval(-3600),
            remoteModTime: Date()
        ), strategy: .newerWins)

        XCTAssertEqual(res.winner, .remote)
        let localContents = try String(contentsOf: local, encoding: .utf8)
        XCTAssertEqual(localContents, "NEW")
    }

    // MARK: - Same-timestamp tie

    func testSameTimestamp_preservesBothCopies() async throws {
        let local = tempDir.appendingPathComponent("doc.md")
        let remote = tempDir.appendingPathComponent("doc-remote.md")
        try "version A".write(to: local, atomically: true, encoding: .utf8)
        try "version B".write(to: remote, atomically: true, encoding: .utf8)
        let now = Date()

        let res = try await resolver.resolve(.init(
            relativePath: "doc.md", localPath: local, remotePath: remote,
            localModTime: now, remoteModTime: now.addingTimeInterval(0.2)
        ), strategy: .newerWins)

        XCTAssertEqual(res.winner, .bothPreserved)
        let aPath = local.deletingLastPathComponent()
            .appendingPathComponent("doc.md.machine-A").path
        let bPath = local.deletingLastPathComponent()
            .appendingPathComponent("doc.md.machine-B").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: aPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bPath))
    }

    // MARK: - JSON merge

    func testJSONMerge_keysFromBothSides_arePreserved() async throws {
        let local = tempDir.appendingPathComponent("settings.json")
        let remote = tempDir.appendingPathComponent("settings-remote.json")
        try #"{"theme":"dark","editor":{"font":"JetBrains Mono"}}"#
            .write(to: local, atomically: true, encoding: .utf8)
        try #"{"telemetry":false,"editor":{"size":14}}"#
            .write(to: remote, atomically: true, encoding: .utf8)

        let res = try await resolver.resolve(.init(
            relativePath: "settings.json", localPath: local, remotePath: remote,
            localModTime: Date(),
            remoteModTime: Date().addingTimeInterval(-60)
        ), strategy: .mergeJSON)

        XCTAssertEqual(res.winner, .mergedInPlace)

        let merged = try JSONSerialization.jsonObject(with: try Data(contentsOf: local)) as? [String: Any]
        XCTAssertEqual(merged?["theme"] as? String, "dark")
        XCTAssertEqual(merged?["telemetry"] as? Bool, false)
        let editor = merged?["editor"] as? [String: Any]
        XCTAssertEqual(editor?["font"] as? String, "JetBrains Mono")
        XCTAssertEqual(editor?["size"] as? Int, 14)
    }

    func testJSONMerge_keyConflict_newerSideWins() async throws {
        let local = tempDir.appendingPathComponent("a.json")
        let remote = tempDir.appendingPathComponent("b.json")
        try #"{"theme":"dark"}"#.write(to: local, atomically: true, encoding: .utf8)
        try #"{"theme":"light"}"#.write(to: remote, atomically: true, encoding: .utf8)

        // local mtime is newer → local value wins
        let res = try await resolver.resolve(.init(
            relativePath: "a.json", localPath: local, remotePath: remote,
            localModTime: Date(),
            remoteModTime: Date().addingTimeInterval(-60)
        ), strategy: .mergeJSON)

        XCTAssertEqual(res.winner, .mergedInPlace)
        let merged = try JSONSerialization.jsonObject(with: try Data(contentsOf: local)) as? [String: Any]
        XCTAssertEqual(merged?["theme"] as? String, "dark")
    }

    func testJSONMerge_unparseableSide_fallsBackToNewerWins() async throws {
        let local = tempDir.appendingPathComponent("ok.json")
        let remote = tempDir.appendingPathComponent("broken.json")
        try #"{"x":1}"#.write(to: local, atomically: true, encoding: .utf8)
        try "not-json".write(to: remote, atomically: true, encoding: .utf8)

        let res = try await resolver.resolve(.init(
            relativePath: "ok.json", localPath: local, remotePath: remote,
            localModTime: Date(),
            remoteModTime: Date().addingTimeInterval(-60)
        ), strategy: .mergeJSON)

        // Falls back to newer wins → local wins → remote should now contain JSON
        XCTAssertEqual(res.winner, .local)
        XCTAssertNotNil(res.backupPath)
    }

    // MARK: - Archive purge

    func testPurgeOlderThan_deletesOldArchives() async throws {
        let oldDir = archiveDir.appendingPathComponent("2024-01-01", isDirectory: true)
        let recentDir = archiveDir.appendingPathComponent("2026-05-05", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)

        // Backdate the old dir by ~60 days.
        let pastDate = Date().addingTimeInterval(-60 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: pastDate],
                                              ofItemAtPath: oldDir.path)

        try await resolver.purgeOlderThan(days: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
            "Old archive should be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentDir.path),
            "Recent archive should be kept")
    }
}
