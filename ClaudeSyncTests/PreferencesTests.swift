import XCTest
@testable import ClaudeSync

final class PreferencesTests: XCTestCase {

    // MARK: - Preferences (model)

    func testDefault_hasUnlimitedBandwidth_andEmptyExtras_andLaunchOff() {
        let p = Preferences.default
        XCTAssertEqual(p.bandwidthLimitKBps, 0)
        XCTAssertTrue(p.extraExcludes.isEmpty)
        XCTAssertFalse(p.launchAtLogin)
    }

    func testEncodeDecode_roundTrip_preservesAllFields() throws {
        let original = Preferences(
            bandwidthLimitKBps: 1024,
            extraExcludes: ["projects": ["*.draft", "secret/"]],
            launchAtLogin: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testIgnorePatterns_includesUserExtras_perTarget() {
        let p = Preferences(extraExcludes: [
            "projects": ["custom-rule/"],
        ])
        let ig = p.ignorePatterns()
        XCTAssertTrue(ig.shouldIgnore(
            absolutePath: "/Users/me/Documents/GitHub/foo/custom-rule/notes.md",
            target: .projects
        ))
        XCTAssertFalse(ig.shouldIgnore(
            absolutePath: "/Users/me/.claude/custom-rule/notes.md",
            target: .claudeConfig
        ))
    }

    func testExtraExcludes_forUnknownRawValue_returnsEmpty() {
        let p = Preferences(extraExcludes: ["bogus": ["a"]])
        XCTAssertEqual(p.extraExcludes(for: .claudeConfig), [])
    }

    // MARK: - PreferencesStore (file-backed)

    func testStore_returnsDefaults_whenFileMissing() async {
        let url = freshTempURL()
        let store = PreferencesStore(fileURL: url)
        let current = await store.current()
        XCTAssertEqual(current, .default)
    }

    func testStore_persistsAndReloads() async throws {
        let url = freshTempURL()
        let store = PreferencesStore(fileURL: url)
        try await store.update { $0.bandwidthLimitKBps = 5000 }

        // Reload from a fresh store instance pointing at the same file.
        let reloaded = PreferencesStore(fileURL: url)
        let current = await reloaded.current()
        XCTAssertEqual(current.bandwidthLimitKBps, 5000)
    }

    func testStore_corruptedFile_fallsBackToDefaults() async throws {
        let url = freshTempURL()
        try Data("not json {".utf8).write(to: url)
        let store = PreferencesStore(fileURL: url)
        let current = await store.current()
        XCTAssertEqual(current, .default)
    }

    func testLoadInitialSync_returnsDefaults_whenMissing() {
        let url = freshTempURL()
        let p = Preferences.loadInitialSync(from: url)
        XCTAssertEqual(p, .default)
    }

    func testLoadInitialSync_decodesWritten() throws {
        let url = freshTempURL()
        let original = Preferences(bandwidthLimitKBps: 256, launchAtLogin: true)
        let data = try JSONEncoder().encode(original)
        try data.write(to: url)

        let loaded = Preferences.loadInitialSync(from: url)
        XCTAssertEqual(loaded, original)
    }

    // MARK: - Helpers

    private func freshTempURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudesync-prefs-test")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("preferences.json")
        try? FileManager.default.createDirectory(
            at: tmp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: tmp)
        return tmp
    }
}
