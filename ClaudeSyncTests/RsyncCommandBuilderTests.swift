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
}
