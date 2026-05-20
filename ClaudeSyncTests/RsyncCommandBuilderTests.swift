import XCTest
@testable import ClaudeSync

final class RsyncCommandBuilderTests: XCTestCase {

    let peer = RsyncCommandBuilder.PeerEndpoint(sshAddress: "kim@MacBookAir.local", sshPort: 22)

    func testFullSync_includesArchiveCompressDeleteUpdateItemize() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)

        XCTAssertEqual(args.first, "/usr/bin/rsync")
        XCTAssertTrue(args.contains("--archive"))
        XCTAssertTrue(args.contains("--compress"))
        XCTAssertTrue(args.contains("--delete"))
        XCTAssertTrue(args.contains("--update"))
        XCTAssertTrue(args.contains("--itemize-changes"))
        XCTAssertTrue(args.contains("--partial"))
        XCTAssertTrue(args.contains("--timeout=30"))
    }

    func testGNUOnlyFlags_areOmittedForSystemRsync() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        XCTAssertFalse(args.contains("--delete-after"))
        XCTAssertFalse(args.contains("--contimeout=10"))
    }

    func testGNUOnlyFlags_arePresentForHomebrewRsync() {
        let builder = RsyncCommandBuilder(rsyncPath: "/opt/homebrew/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        XCTAssertTrue(args.contains("--delete-after"))
        XCTAssertTrue(args.contains("--contimeout=10"))
    }

    func testPushDirection_orderingIsLocalThenRemote() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .codexConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        let last = args.suffix(2)
        XCTAssertFalse(last.first?.contains("@") ?? true, "Local path comes first")
        XCTAssertTrue(last.last?.contains("@") ?? false, "Remote path comes last")
    }

    func testPullDirection_orderingIsRemoteThenLocal() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .codexConfig, direction: .pull)
        let args = builder.build(job: job, peer: peer)
        let last = args.suffix(2)
        XCTAssertTrue(last.first?.contains("@") ?? false)
        XCTAssertFalse(last.last?.contains("@") ?? true)
    }

    func testSSHCommand_includesIdentityAndPort() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/mykey")
        let cmd = builder.sshCommand(for: .init(sshAddress: "kim@host.local", sshPort: 2200))
        XCTAssertTrue(cmd.contains("-i /tmp/mykey"))
        XCTAssertTrue(cmd.contains("-p 2200"))
        XCTAssertTrue(cmd.contains("BatchMode=yes"))
    }

    func testTargetExcludes_arePropagatedToArgs() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .projects, direction: .push)
        let args = builder.build(job: job, peer: peer)
        // projects spec excludes node_modules/
        let excludes = zip(args, args.dropFirst()).compactMap { (a, b) -> String? in
            a == "--exclude" ? b : nil
        }
        XCTAssertTrue(excludes.contains("node_modules/"))
        XCTAssertTrue(excludes.contains(".DS_Store"))
    }

    func testSecurityExcludes_areAlwaysEmitted() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .codexConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        let excludes = zip(args, args.dropFirst()).compactMap { (a, b) -> String? in
            a == "--exclude" ? b : nil
        }
        XCTAssertTrue(excludes.contains("credentials.json"))
        XCTAssertTrue(excludes.contains("oauth_token*"))
    }

    func testDryRun_addsDryRunFlag() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync", sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .codexConfig, direction: .push)
        let args = builder.build(job: job, peer: peer, dryRun: true)
        XCTAssertTrue(args.contains("--dry-run"))
    }

    func testDetectBinary_returnsHomebrewWhenAvailable() {
        // Just verify we get one of the two known paths.
        let detected = RsyncCommandBuilder.detectRsyncBinary()
        XCTAssertTrue(detected == "/opt/homebrew/bin/rsync" || detected == "/usr/bin/rsync")
    }

    func testBandwidthLimit_emitsBwlimitArg_whenPositive() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key",
                                          bandwidthLimitKBps: 2048)
        let job = SyncJob(target: .codexConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        XCTAssertTrue(args.contains("--bwlimit=2048"),
                      "expected --bwlimit=2048, got: \(args)")
    }

    func testBandwidthLimit_omitsBwlimitArg_whenZero() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key",
                                          bandwidthLimitKBps: 0)
        let job = SyncJob(target: .codexConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("--bwlimit") }))
    }

    func testUserExtraExcludes_areEmittedForMatchingTarget() {
        let extras: [SyncTarget: [String]] = [.projects: ["secret-notes/", "*.draft"]]
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key",
                                          userExtraExcludes: extras)
        let job = SyncJob(target: .projects, direction: .push)
        let args = builder.build(job: job, peer: peer)
        let emittedExcludes = zip(args, args.dropFirst()).compactMap { (a, b) -> String? in
            a == "--exclude" ? b : nil
        }
        XCTAssertTrue(emittedExcludes.contains("secret-notes/"))
        XCTAssertTrue(emittedExcludes.contains("*.draft"))
    }

    func testUserExtraExcludes_doNotLeakIntoOtherTargets() {
        let extras: [SyncTarget: [String]] = [.projects: ["only-projects-pattern"]]
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key",
                                          userExtraExcludes: extras)
        let job = SyncJob(target: .codexConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        let emittedExcludes = zip(args, args.dropFirst()).compactMap { (a, b) -> String? in
            a == "--exclude" ? b : nil
        }
        XCTAssertFalse(emittedExcludes.contains("only-projects-pattern"))
    }

    // MARK: - SAFETY-001 — trash quarantine + protect-from-delete

    private func filterRules(in args: [String]) -> [String] {
        zip(args, args.dropFirst()).compactMap { (a, b) -> String? in
            a == "--filter" ? b : nil
        }
    }

    private func backupDir(in args: [String]) -> String? {
        args.first(where: { $0.hasPrefix("--backup-dir=") })?
            .replacingOccurrences(of: "--backup-dir=", with: "")
    }

    func testClaudeConfig_emitsProtectFilters_forCleanupSubpaths() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        let filters = filterRules(in: args)
        // Each protected subpath becomes `P <subpath>***` so it survives
        // peer-side cleanup propagation.
        XCTAssertTrue(filters.contains("P sessions/***"),
                      "expected protect filter for sessions/, got: \(filters)")
        XCTAssertTrue(filters.contains("P file-history/***"))
        XCTAssertTrue(filters.contains("P backups/***"))
        XCTAssertTrue(filters.contains("P projects/***"))
        XCTAssertTrue(filters.contains("P shell-snapshots/***"))
        XCTAssertTrue(filters.contains("P transcripts/***"))
    }

    func testOtherTargets_doNotEmitProtectFilters_byDefault() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        for target: SyncTarget in [.claudeAppSupport, .codexConfig, .projects] {
            let job = SyncJob(target: target, direction: .push)
            let args = builder.build(job: job, peer: peer)
            XCTAssertTrue(filterRules(in: args).isEmpty,
                          "\(target.rawValue) should not emit --filter rules by default")
        }
    }

    func testLastCleanupMarker_isExcluded_forClaudeConfig() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        let excludes = zip(args, args.dropFirst()).compactMap { (a, b) -> String? in
            a == "--exclude" ? b : nil
        }
        XCTAssertTrue(excludes.contains(".last-cleanup"),
                      ".last-cleanup must never propagate to peer")
    }

    func testTrashQuarantine_push_targetsRemoteUsersDir() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        XCTAssertTrue(args.contains("--backup"),
                      "expected --backup to be paired with --backup-dir")
        let dir = backupDir(in: args)
        XCTAssertNotNil(dir)
        // peer is `kim@MacBookAir.local` → trash on the remote at
        // /Users/kim/.claudesync/trash/<uuid>/
        XCTAssertTrue(dir?.hasPrefix("/Users/kim/.claudesync/trash/") ?? false,
                      "trash dir must root at peer's home, got: \(dir ?? "<nil>")")
        XCTAssertTrue(dir?.hasSuffix("/") ?? false,
                      "trash dir must end with trailing slash so rsync treats it as a dir")
        // Each job gets a unique UUID bucket so concurrent jobs don't
        // collide on the same directory.
        let bucket = dir?
            .replacingOccurrences(of: "/Users/kim/.claudesync/trash/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        XCTAssertNotNil(UUID(uuidString: bucket ?? ""),
                        "trash bucket name must be the job's UUID")
    }

    func testTrashQuarantine_pull_targetsLocalHome() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        let job = SyncJob(target: .claudeConfig, direction: .pull)
        let args = builder.build(job: job, peer: peer)
        let dir = backupDir(in: args)
        XCTAssertNotNil(dir)
        let expectedPrefix = NSHomeDirectory() + "/.claudesync/trash/"
        XCTAssertTrue(dir?.hasPrefix(expectedPrefix) ?? false,
                      "pull trash dir should live in local home, got: \(dir ?? "<nil>")")
    }

    func testTrashQuarantine_canBeDisabled() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key",
                                          trashQuarantineEnabled: false)
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: peer)
        XCTAssertFalse(args.contains("--backup"))
        XCTAssertNil(backupDir(in: args))
    }

    func testTrashQuarantine_skipsWhenSshAddressLacksUserPart() {
        let builder = RsyncCommandBuilder(rsyncPath: "/usr/bin/rsync",
                                          sshKeyPath: "/tmp/key")
        // Malformed address (no `user@` prefix) → builder should refuse
        // to emit a nonsense backup-dir rather than write to /Users//...
        let weirdPeer = RsyncCommandBuilder.PeerEndpoint(sshAddress: "host.local",
                                                         sshPort: 22)
        let job = SyncJob(target: .claudeConfig, direction: .push)
        let args = builder.build(job: job, peer: weirdPeer)
        XCTAssertNil(backupDir(in: args))
    }
}
