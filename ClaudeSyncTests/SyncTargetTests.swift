import XCTest
@testable import ClaudeSync

final class SyncTargetTests: XCTestCase {

    func testAllTargetsHaveSpecs() {
        for target in SyncTarget.allCases {
            let spec = target.spec
            XCTAssertEqual(spec.target, target)
            XCTAssertFalse(spec.basePath.isEmpty)
            XCTAssertFalse(spec.watchPaths.isEmpty)
        }
    }

    func testClaudeConfig_sessionsSubpath_isBatched() {
        let spec = SyncTarget.claudeConfig.spec
        XCTAssertEqual(spec.tier(forRelativePath: "settings.json"), .realtime)
        XCTAssertEqual(spec.tier(forRelativePath: "hooks/pre-commit.sh"), .realtime)
        XCTAssertEqual(spec.tier(forRelativePath: "sessions/abc.jsonl"), .batched)
        XCTAssertEqual(spec.tier(forRelativePath: "transcripts/x.md"), .batched)
    }

    func testProjects_isOnDemand_andSupportsLocalIgnore() {
        let spec = SyncTarget.projects.spec
        XCTAssertEqual(spec.defaultTier, .onDemand)
        XCTAssertTrue(spec.supportsProjectIgnoreFile)
        XCTAssertEqual(spec.tier(forRelativePath: "myproject/src/main.go"), .onDemand)
    }

    func testTildeExpansion() {
        XCTAssertEqual(
            "~/.claude".expandingTildeInPath,
            NSHomeDirectory() + "/.claude"
        )
        XCTAssertEqual(
            "/absolute/path".expandingTildeInPath,
            "/absolute/path",
            "Non-tilde paths should be returned unchanged"
        )
    }

    func testSyncTier_isOrdered() {
        XCTAssertLessThan(SyncTier.realtime, SyncTier.batched)
        XCTAssertLessThan(SyncTier.batched, SyncTier.onDemand)
    }
}

final class IgnorePatternsTests: XCTestCase {
    let patterns = IgnorePatterns()

    func testGlobalDefaults_DSStore_isIgnored() {
        XCTAssertTrue(
            patterns.shouldIgnore(absolutePath: "/Users/kim/.claude/.DS_Store",
                                  target: .claudeConfig)
        )
    }

    func testSecurityPatterns_credentialsAlwaysIgnored() {
        XCTAssertTrue(
            patterns.shouldIgnore(absolutePath: "/Users/kim/.claude/credentials.json",
                                  target: .claudeConfig)
        )
        XCTAssertTrue(
            patterns.shouldIgnore(absolutePath: "/anywhere/oauth_token_v2",
                                  target: .projects)
        )
    }

    func testProjects_nodeModules_isIgnored() {
        XCTAssertTrue(
            patterns.shouldIgnore(
                absolutePath: "/Users/kim/Documents/GitHub/myproj/node_modules/lodash/index.js",
                target: .projects
            )
        )
    }

    func testProjects_normalSourceFile_isAllowed() {
        XCTAssertFalse(
            patterns.shouldIgnore(
                absolutePath: "/Users/kim/Documents/GitHub/myproj/src/index.ts",
                target: .projects
            )
        )
    }

    func testClaudeConfig_lockFile_isIgnored() {
        XCTAssertTrue(
            patterns.shouldIgnore(
                absolutePath: "/Users/kim/.claude/sessions/transcript.lock",
                target: .claudeConfig
            )
        )
    }

    func testClaudeAppSupport_cacheDir_isIgnored() {
        XCTAssertTrue(
            patterns.shouldIgnore(
                absolutePath: "/Users/kim/Library/Application Support/Claude/Cache/data.bin",
                target: .claudeAppSupport
            )
        )
    }

    func testFnmatch_wildcards() {
        XCTAssertTrue(IgnorePatterns.fnmatch(pattern: "*.log", name: "build.log"))
        XCTAssertTrue(IgnorePatterns.fnmatch(pattern: "*.log", name: ".log"))
        XCTAssertFalse(IgnorePatterns.fnmatch(pattern: "*.log", name: "log"))
        XCTAssertTrue(IgnorePatterns.fnmatch(pattern: "oauth_token*", name: "oauth_token_v2"))
        XCTAssertTrue(IgnorePatterns.fnmatch(pattern: "?.swp", name: "a.swp"))
        XCTAssertFalse(IgnorePatterns.fnmatch(pattern: "?.swp", name: "ab.swp"))
    }

    func testUserExtra_appliesAdditionalPatterns() {
        let custom = IgnorePatterns(
            userExtra: [.projects: ["*.psd"]]
        )
        XCTAssertTrue(
            custom.shouldIgnore(absolutePath: "/Users/kim/Documents/GitHub/x/art.psd",
                                target: .projects)
        )
        // Default-only pattern still works
        XCTAssertTrue(
            custom.shouldIgnore(absolutePath: "/Users/kim/Documents/GitHub/x/.DS_Store",
                                target: .projects)
        )
    }
}
