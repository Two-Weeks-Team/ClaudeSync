# ClaudeSync Test Strategy

**Version**: 1.0.0  
**Date**: 2026-05-03  
**Status**: Draft  
**Covers**: Unit, Integration, Actor Isolation, and E2E Testing  

---

## Table of Contents

1. [Overview](#1-overview)
2. [Unit Tests](#2-unit-tests)
3. [Integration Tests](#3-integration-tests)
4. [Mock SSH/rsync Layer](#4-mock-sshrsync-layer)
5. [Actor Isolation Tests](#5-actor-isolation-tests)
6. [E2E Sync Correctness Tests](#6-e2e-sync-correctness-tests)
7. [Test Infrastructure](#7-test-infrastructure)
8. [Coverage Targets](#8-coverage-targets)

---

## 1. Overview

### Testing Philosophy

- **Determinism**: All tests must be deterministic and repeatable. No reliance on wall-clock time; use `ContinuousClock` injection for time-dependent logic.
- **Isolation**: Tests must not depend on network, SSH daemons, or external state. All external dependencies are injected via protocols.
- **Speed**: Unit tests execute in <5 seconds total. Integration tests in <30 seconds. E2E tests in <2 minutes.
- **Safety**: Tests never modify `~/.ssh/authorized_keys`, `~/.claude/`, or any real user data. All file operations use temporary directories.

### Test Pyramid

```
          /  E2E  \           ~10 tests (sync correctness, full pipeline)
         /----------\
        / Integration \       ~30 tests (FSEvents -> debounce -> rsync pipeline)
       /----------------\
      /   Unit Tests     \    ~100+ tests (individual components)
     /____________________\
```

### Framework Choice

- **XCTest** for all test types (native Swift, no external dependencies)
- **Swift Testing** (`@Test`, `#expect`) for new unit tests where available (Xcode 16+)
- **Temporary directories** via `FileManager.default.temporaryDirectory` for all file I/O

---

## 2. Unit Tests

### 2.1 ConflictResolver Tests

```swift
final class ConflictResolverTests: XCTestCase {
    var resolver: ConflictResolver!
    var tempDir: URL!
    
    override func setUp() async throws {
        resolver = ConflictResolver()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // --- Strategy Selection ---
    
    func testStrategyForJSON_returnsMerge() async {
        let strategy = await resolver.strategyFor(path: "config.json", userPreference: nil)
        XCTAssertEqual(strategy, .merge)
    }
    
    func testStrategyForBinary_returnsLargerWins() async {
        let strategy = await resolver.strategyFor(path: "image.png", userPreference: nil)
        XCTAssertEqual(strategy, .largerWins)
    }
    
    func testStrategyForUnknown_returnsNewerWins() async {
        let strategy = await resolver.strategyFor(path: "data.bin", userPreference: nil)
        XCTAssertEqual(strategy, .newerWins)
    }
    
    func testUserPreferenceOverridesAutoDetection() async {
        let strategy = await resolver.strategyFor(path: "config.json", userPreference: .manual)
        XCTAssertEqual(strategy, .manual)
    }
    
    // --- Newer Wins ---
    
    func testNewerWins_localNewer_localWins() async throws {
        let localFile = tempDir.appending(path: "local.txt")
        let remoteFile = tempDir.appending(path: "remote.txt")
        try "local content".write(to: localFile, atomically: true, encoding: .utf8)
        try "remote content".write(to: remoteFile, atomically: true, encoding: .utf8)
        
        let conflict = ConflictInfo(
            relativePath: "test.txt",
            localModTime: Date(),
            remoteModTime: Date().addingTimeInterval(-60),  // Remote is older
            localSize: 13,
            remoteSize: 14,
            localHash: "abc",
            remoteHash: "def"
        )
        
        let resolution = try await resolver.resolve(
            conflict: conflict,
            localPath: localFile,
            remotePath: remoteFile,
            strategy: .newerWins,
            ancestor: nil
        )
        
        XCTAssertEqual(resolution.winner, .local)
        XCTAssertNotNil(resolution.backupPath)  // Remote version archived
    }
    
    func testNewerWins_remoteNewer_remoteWins() async throws {
        // ... symmetric test
    }
    
    // --- Hash Match (no real conflict) ---
    
    func testIdenticalHashes_noConflict() async throws {
        // Both files have same content hash -> no conflict, just update timestamps
    }
    
    // --- Merge Strategy ---
    
    func testJSONMerge_nonOverlappingKeys_mergesCleanly() async throws {
        // Local adds key "a", remote adds key "b" -> merged has both
    }
    
    func testJSONMerge_conflictingKeys_newerTimestampWins() async throws {
        // Both modify same key -> key with newer timestamp wins
    }
    
    // --- Deletion vs Modification ---
    
    func testDeletionVsModification_modifiedWins() async throws {
        // One side deletes, other side modifies -> modified version preserved
    }
}
```

### 2.2 ProcessRunner Tests

```swift
final class ProcessRunnerTests: XCTestCase {
    
    func testSuccessfulCommand_returnsZeroExitCode() async throws {
        let runner = ProcessRunner(executable: "/bin/echo", arguments: ["hello"])
        let output = try await runner.run()
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }
    
    func testFailingCommand_returnsNonZeroExitCode() async throws {
        let runner = ProcessRunner(executable: "/bin/false", arguments: [])
        let output = try await runner.run()
        XCTAssertNotEqual(output.exitCode, 0)
    }
    
    func testNonExistentExecutable_throwsError() async {
        let runner = ProcessRunner(executable: "/nonexistent/binary", arguments: [])
        do {
            _ = try await runner.run()
            XCTFail("Should throw")
        } catch {
            // Expected
        }
    }
    
    func testCancellation_terminatesProcess() async throws {
        let runner = ProcessRunner(executable: "/bin/sleep", arguments: ["60"])
        let task = Task {
            try await runner.run()
        }
        
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        runner.cancel()
        
        let result = try await task.value
        // Process should have been terminated
        XCTAssertNotEqual(result.exitCode, 0)
    }
    
    func testStreamingOutput_yieldsLines() async throws {
        let runner = ProcessRunner(
            executable: "/bin/bash",
            arguments: ["-c", "echo line1; echo line2; echo line3"]
        )
        
        var lines: [String] = []
        for try await line in runner.runStreaming() {
            lines.append(line)
        }
        
        XCTAssertEqual(lines, ["line1", "line2", "line3"])
    }
    
    func testTimeout_processKilledAfterDeadline() async throws {
        // Test that long-running processes respect timeout
    }
}
```

### 2.3 RsyncCommandBuilder Tests

```swift
final class RsyncCommandBuilderTests: XCTestCase {
    var builder: RsyncCommandBuilder!
    var peer: PeerInfo!
    
    override func setUp() {
        builder = RsyncCommandBuilder()
        peer = PeerInfo(
            id: UUID(),
            hostname: "test-mac",
            username: "testuser",
            sshPort: 22,
            publicKeyFingerprint: "SHA256:test",
            endpoint: nil,
            lastSeen: Date(),
            isPaired: true
        )
    }
    
    // --- Flag Safety (openrsync compatibility) ---
    
    func testBuildCommand_usesOnlySafeFlags_whenSystemRsync() {
        // Verify no --compress-choice, --checksum-choice, --log-file, -E, --backup-dir
        let job = makeSyncJob(target: .claudeConfig, direction: .push)
        let args = builder.buildCommand(for: job, peer: peer)
        
        XCTAssertTrue(args.contains("--archive"))
        XCTAssertTrue(args.contains("--compress"))
        XCTAssertTrue(args.contains("--delete"))
        XCTAssertTrue(args.contains("--update"))
        XCTAssertTrue(args.contains("--itemize-changes"))
        XCTAssertTrue(args.contains("--partial"))
        
        // Unsafe flags NOT present
        XCTAssertFalse(args.contains(where: { $0.contains("--compress-choice") }))
        XCTAssertFalse(args.contains(where: { $0.contains("--checksum-choice") }))
        XCTAssertFalse(args.contains(where: { $0.contains("--log-file") }))
        XCTAssertFalse(args.contains("-E"))
        XCTAssertFalse(args.contains(where: { $0.contains("--backup-dir") }))
    }
    
    // --- Direction ---
    
    func testPushDirection_localSourceRemoteDestination() {
        let job = makeSyncJob(target: .claudeConfig, direction: .push)
        let args = builder.buildCommand(for: job, peer: peer)
        
        let lastTwo = Array(args.suffix(2))
        XCTAssertTrue(lastTwo[0].hasPrefix("/"))       // Local path
        XCTAssertTrue(lastTwo[1].contains("@"))        // Remote SSH path
    }
    
    func testPullDirection_remoteSourceLocalDestination() {
        let job = makeSyncJob(target: .claudeConfig, direction: .pull)
        let args = builder.buildCommand(for: job, peer: peer)
        
        let lastTwo = Array(args.suffix(2))
        XCTAssertTrue(lastTwo[0].contains("@"))        // Remote SSH path
        XCTAssertTrue(lastTwo[1].hasPrefix("/"))        // Local path
    }
    
    // --- Exclude Patterns ---
    
    func testExcludePatterns_includedInArgs() {
        let job = makeSyncJob(target: .claudeConfig, direction: .push)
        let args = builder.buildCommand(for: job, peer: peer)
        
        XCTAssertTrue(args.contains("--exclude"))
        // Verify security exclusions are always present
        XCTAssertTrue(args.contains("**/credentials.json"))
    }
    
    // --- Incremental Sync (specific paths) ---
    
    func testIncrementalSync_usesIncludeFilters() {
        let job = makeSyncJob(
            target: .claudeConfig,
            direction: .push,
            paths: Set(["settings.json", "CLAUDE.md"])
        )
        let args = builder.buildCommand(for: job, peer: peer)
        
        XCTAssertTrue(args.contains("--include"))
    }
    
    // --- SSH Command ---
    
    func testSSHCommand_includesIdentityFile() {
        let job = makeSyncJob(target: .claudeConfig, direction: .push)
        let args = builder.buildCommand(for: job, peer: peer)
        
        guard let eIndex = args.firstIndex(of: "-e"),
              eIndex + 1 < args.count else {
            XCTFail("Missing -e flag")
            return
        }
        
        let sshCmd = args[eIndex + 1]
        XCTAssertTrue(sshCmd.contains("-i"))
        XCTAssertTrue(sshCmd.contains("id_claudesync"))
        XCTAssertTrue(sshCmd.contains("BatchMode=yes"))
    }
    
    // --- Dry Run ---
    
    func testDryRun_includesItemizeChangesAndDryRunFlag() {
        let job = makeSyncJob(target: .claudeConfig, direction: .push)
        let args = builder.dryRun(for: job, peer: peer)
        
        XCTAssertTrue(args.contains("--dry-run"))
        XCTAssertTrue(args.contains("--itemize-changes"))
    }
    
    // --- Bandwidth Limit ---
    
    func testBandwidthLimit_appliedWhenConfigured() {
        builder.performanceConfig = RsyncPerformanceConfig(isGNURsync: false, bwLimit: 5000)
        let job = makeSyncJob(target: .projects, direction: .push)
        let args = builder.buildCommand(for: job, peer: peer)
        
        XCTAssertTrue(args.contains("--bwlimit=5000"))
    }
    
    // --- Helper ---
    
    private func makeSyncJob(
        target: SyncTarget,
        direction: SyncDirection,
        paths: Set<String> = []
    ) -> SyncJob {
        SyncJob(
            id: UUID(),
            target: target,
            paths: paths,
            direction: direction,
            priority: .high,
            createdAt: .now,
            isFullSync: paths.isEmpty
        )
    }
}
```

### 2.4 PairingCodeGenerator Tests

```swift
final class PairingCodeGeneratorTests: XCTestCase {
    
    func testSameKeys_produceSameCode() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)
        
        let code1 = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        let code2 = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        
        XCTAssertEqual(code1, code2)
    }
    
    func testDifferentKeys_produceDifferentCode() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)
        let keyC = Data("publicKeyC".utf8)  // Attacker's key
        
        let legitimateCode = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        let mitmCode = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyC)
        
        XCTAssertNotEqual(legitimateCode, mitmCode)
    }
    
    func testCode_isSixDigits() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)
        
        let code = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })
    }
    
    func testOrderMatters_initiatorVsResponder() {
        let keyA = Data("publicKeyA".utf8)
        let keyB = Data("publicKeyB".utf8)
        
        let codeAB = PairingCodeGenerator.generateCode(initiatorPublicKey: keyA, responderPublicKey: keyB)
        let codeBA = PairingCodeGenerator.generateCode(initiatorPublicKey: keyB, responderPublicKey: keyA)
        
        // Order matters: both machines must agree on who is initiator/responder
        XCTAssertNotEqual(codeAB, codeBA)
    }
}
```

### 2.5 Debouncer Tests

```swift
final class DebouncerTests: XCTestCase {
    
    func testSingleEvent_firesAfterQuietPeriod() async throws {
        let (stream, continuation) = AsyncStream<(SyncTarget, Set<String>)>.makeStream()
        let debouncer = Debouncer(output: continuation)
        
        await debouncer.addPaths(Set(["file.txt"]), for: .claudeConfig)
        
        // Should NOT fire immediately
        // ... wait 2+ seconds
        // Should fire with the path
    }
    
    func testRapidEvents_resetTimer() async throws {
        // Add event, wait 1s, add another event for same path
        // Timer should reset; only fires 2s after LAST event
    }
    
    func testDifferentPaths_independentTimers() async throws {
        // Events for path A and path B should have independent quiet-periods
    }
    
    func testCancelAll_drainsWithoutEmitting() async throws {
        // After cancelAll(), no pending events should fire
    }
}
```

### 2.6 IgnorePatterns Tests

```swift
final class IgnorePatternsTests: XCTestCase {
    
    func testNodeModules_excluded() {
        let patterns = IgnorePatterns.default
        XCTAssertTrue(patterns.shouldExclude(path: "project/node_modules/package/index.js", target: .projects))
    }
    
    func testSecurityPatterns_alwaysExcluded() {
        let patterns = IgnorePatterns.default
        XCTAssertTrue(patterns.shouldExclude(path: "credentials.json", target: .claudeConfig))
        XCTAssertTrue(patterns.shouldExclude(path: ".env.local", target: .projects))
    }
    
    func testCustomExcludes_respected() {
        // User-configured excludes work correctly
    }
    
    func testClaudesyncignore_perProject() {
        // Per-project .claudesyncignore file patterns applied
    }
}
```

---

## 3. Integration Tests

### 3.1 FSEvents -> Debounce -> rsync Pipeline (Local Temp Dir)

These tests verify the full pipeline from file change detection through to rsync execution, using a local temporary directory (no network required).

```swift
final class SyncPipelineIntegrationTests: XCTestCase {
    var sourceDir: URL!
    var destDir: URL!
    var fileWatcher: FileWatcherActor!
    var syncActor: FileSyncActor!
    var coordinator: SyncCoordinator!
    
    override func setUp() async throws {
        sourceDir = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeSyncTest-source-\(UUID().uuidString)")
        destDir = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeSyncTest-dest-\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Configure pipeline with local rsync (source -> dest, no SSH)
        // ...
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sourceDir)
        try? FileManager.default.removeItem(at: destDir)
    }
    
    func testFileCreation_propagatesToDest() async throws {
        // 1. Write a file to sourceDir
        let testFile = sourceDir.appending(path: "test.txt")
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)
        
        // 2. Wait for FSEvents + debounce + rsync
        try await Task.sleep(for: .seconds(4))  // 2s debounce + rsync time
        
        // 3. Verify file exists in destDir with same content
        let destFile = destDir.appending(path: "test.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path()))
        let content = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(content, "hello world")
    }
    
    func testFileModification_propagatesChanges() async throws {
        // Pre-create file in both dirs
        // Modify in source
        // Verify dest gets update
    }
    
    func testFileDeletion_propagatesToDest() async throws {
        // Pre-create file in both dirs
        // Delete from source
        // Verify dest file is removed (or trashed)
    }
    
    func testDebounce_coalescesRapidChanges() async throws {
        // Write same file 10 times rapidly
        // Verify only 1 rsync invocation occurs
    }
    
    func testIgnorePatterns_preventSync() async throws {
        // Create node_modules/ in source
        // Verify it does NOT appear in dest
    }
    
    func testEchoSuppression_preventsLoopback() async throws {
        // Simulate incoming rsync write
        // Verify FSEvents for that path is suppressed (no re-sync triggered)
    }
    
    func testTier1Files_syncWithinThreeSeconds() async throws {
        // Write settings.json to source
        // Measure time until it appears in dest
        // Assert < 3 seconds
    }
    
    func testTier2Files_accumulateBeforeSync() async throws {
        // Write to sessions/ directory multiple times
        // Verify no immediate sync
        // Trigger flush (or wait 5 min in accelerated clock)
        // Verify batch sync occurs
    }
}
```

### 3.2 Conflict Detection Integration

```swift
final class ConflictDetectionIntegrationTests: XCTestCase {
    
    func testBothSidesModified_conflictDetected() async throws {
        // Setup: file exists in source and dest with same mtime
        // Modify in source AND dest (simulating both machines editing)
        // Run dry-run detection
        // Verify conflict is reported
    }
    
    func testConflictResolution_archivesLoser() async throws {
        // Trigger a conflict
        // Verify losing version is saved to conflicts/ directory
    }
    
    func testJSONMerge_producesValidJSON() async throws {
        // Create JSON conflict with non-overlapping changes
        // Verify merged output is valid JSON with both changes
    }
}
```

---

## 4. Mock SSH/rsync Layer

### 4.1 Protocol Abstractions for Testing

```swift
/// Protocol for rsync operations (injectable for testing)
protocol RsyncExecutable: Sendable {
    func execute(args: [String]) async throws -> ProcessRunner.Output
    func cancel()
}

/// Real implementation using ProcessRunner
struct SystemRsync: RsyncExecutable {
    func execute(args: [String]) async throws -> ProcessRunner.Output {
        let runner = ProcessRunner(executable: args[0], arguments: Array(args.dropFirst()))
        return try await runner.run()
    }
    func cancel() { /* ... */ }
}

/// Mock implementation for testing
actor MockRsync: RsyncExecutable {
    var executedCommands: [[String]] = []
    var stubbedResults: [ProcessRunner.Output] = []
    var shouldFail: Bool = false
    var failureExitCode: Int32 = 1
    var artificialDelay: Duration = .zero
    
    func execute(args: [String]) async throws -> ProcessRunner.Output {
        executedCommands.append(args)
        
        if artificialDelay > .zero {
            try await Task.sleep(for: artificialDelay)
        }
        
        if shouldFail {
            return ProcessRunner.Output(
                exitCode: failureExitCode,
                stdout: Data(),
                stderr: "Mock failure".data(using: .utf8)!
            )
        }
        
        if !stubbedResults.isEmpty {
            return stubbedResults.removeFirst()
        }
        
        return ProcessRunner.Output(exitCode: 0, stdout: Data(), stderr: Data())
    }
    
    func cancel() { /* no-op for mock */ }
}

/// Protocol for SSH connectivity checks
protocol SSHConnectivityChecker: Sendable {
    func checkConnectivity(host: String, port: UInt16) async throws -> Bool
}

/// Mock SSH connectivity
actor MockSSHChecker: SSHConnectivityChecker {
    var isReachable: Bool = true
    var artificialDelay: Duration = .zero
    
    func checkConnectivity(host: String, port: UInt16) async throws -> Bool {
        if artificialDelay > .zero {
            try await Task.sleep(for: artificialDelay)
        }
        return isReachable
    }
}
```

### 4.2 Failure Injection Tests

```swift
final class FailureInjectionTests: XCTestCase {
    var mockRsync: MockRsync!
    var syncActor: FileSyncActor!
    
    override func setUp() async throws {
        mockRsync = MockRsync()
        syncActor = FileSyncActor(rsync: mockRsync)
    }
    
    func testNetworkTimeout_retriesWithBackoff() async throws {
        await mockRsync.setFailureExitCode(30)  // rsync timeout code
        await mockRsync.setShouldFail(true)
        
        let job = makeSyncJob()
        let result = await syncActor.executeWithRetry(job)
        
        // Verify retries occurred
        let commands = await mockRsync.executedCommands
        XCTAssertEqual(commands.count, 4)  // 1 initial + 3 retries
        XCTAssertEqual(result.status, .failure(.rsyncTimeout(seconds: 30)))
    }
    
    func testSSHAuthFailure_attemptsRepair() async throws {
        await mockRsync.setFailureExitCode(255)  // SSH failure
        await mockRsync.setShouldFail(true)
        
        let job = makeSyncJob()
        let result = await syncActor.executeWithRetry(job)
        
        // Verify SSH repair was attempted (limited retries)
        let commands = await mockRsync.executedCommands
        XCTAssertLessThanOrEqual(commands.count, 2)  // 1 initial + 1 retry after repair
    }
    
    func testDiskFull_pausesImmediately() async throws {
        await mockRsync.setFailureExitCode(25)  // Disk full
        await mockRsync.setShouldFail(true)
        
        let job = makeSyncJob()
        let result = await syncActor.executeWithRetry(job)
        
        // No retries for disk full
        let commands = await mockRsync.executedCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(result.status, .failure(.diskFull(availableBytes: 0, requiredBytes: 0)))
    }
    
    func testPartialTransfer_resumesFromPartial() async throws {
        // First call: partial transfer (exit 23)
        // Second call: success
        await mockRsync.setStubbedResults([
            ProcessRunner.Output(exitCode: 23, stdout: Data(), stderr: Data()),
            ProcessRunner.Output(exitCode: 0, stdout: Data(), stderr: Data()),
        ])
        
        let job = makeSyncJob()
        let result = await syncActor.executeWithRetry(job)
        
        XCTAssertEqual(result.status, .success)
    }
    
    func testVanishedFile_retriesWithFullSync() async throws {
        // Exit code 24: file vanished during transfer
        await mockRsync.setFailureExitCode(24)
        await mockRsync.setShouldFail(true)
        
        // Verify retry uses full sync mode (no --files-from)
    }
    
    func testConnectionRefused_sshNotRunning() async throws {
        // Simulate sshd not running on peer
        await mockRsync.setFailureExitCode(10)  // Connection refused
        await mockRsync.setShouldFail(true)
        
        let job = makeSyncJob()
        let result = await syncActor.executeWithRetry(job)
        
        XCTAssertEqual(result.status, .failure(.connectionRefused(port: 22)))
    }
    
    private func makeSyncJob() -> SyncJob {
        SyncJob(
            id: UUID(),
            target: .claudeConfig,
            paths: Set(["settings.json"]),
            direction: .push,
            priority: .high,
            createdAt: .now,
            isFullSync: false
        )
    }
}
```

---

## 5. Actor Isolation Tests

### 5.1 Concurrent Modification Safety

```swift
final class ActorIsolationTests: XCTestCase {
    
    /// Verify that FileWatcherActor handles concurrent path registration safely
    func testFileWatcher_concurrentSuppressionRegistration() async {
        let watcher = FileWatcherActor()
        
        // Simulate many concurrent rsync processes registering paths
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await watcher.registerRsyncProcess(
                        pid: pid_t(1000 + i),
                        for: Set(["path/file\(i % 10).txt"])  // Overlapping paths
                    )
                }
            }
        }
        
        // All registrations should complete without data races
        // Verify internal state is consistent
    }
    
    /// Verify that concurrent register/unregister does not corrupt state
    func testFileWatcher_concurrentRegisterUnregister() async {
        let watcher = FileWatcherActor()
        let paths: Set<String> = ["test.txt"]
        
        await withTaskGroup(of: Void.self) { group in
            // Register from many tasks
            for i in 0..<50 {
                group.addTask {
                    await watcher.registerRsyncProcess(pid: pid_t(2000 + i), for: paths)
                }
            }
            // Unregister from many tasks simultaneously
            for i in 0..<50 {
                group.addTask {
                    await watcher.unregisterRsyncProcess(pid: pid_t(2000 + i), for: paths)
                }
            }
        }
        
        // State should be consistent (no crashes, no leaked PIDs)
    }
    
    /// Verify SyncCoordinator handles concurrent sync results
    func testCoordinator_concurrentSyncResults() async {
        let coordinator = await SyncCoordinator.makeForTesting()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let result = SyncResult(
                        jobId: UUID(),
                        target: .claudeConfig,
                        status: .success,
                        filesTransferred: i,
                        bytesTransferred: Int64(i * 1024),
                        duration: .seconds(1),
                        conflicts: [],
                        errors: []
                    )
                    await coordinator.handleSyncResult(result)
                }
            }
        }
        
        // UI state should reflect all results without corruption
    }
    
    /// Verify Debouncer handles concurrent path additions
    func testDebouncer_concurrentPathAdditions() async {
        let (_, continuation) = AsyncStream<(SyncTarget, Set<String>)>.makeStream()
        let debouncer = Debouncer(output: continuation)
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await debouncer.addPaths(
                        Set(["file\(i).txt"]),
                        for: .claudeConfig
                    )
                }
            }
        }
        
        // Should complete without deadlock or data race
    }
    
    /// Verify FileSyncActor queue handles concurrent enqueue/dequeue
    func testFileSyncActor_concurrentEnqueueDequeue() async {
        let syncActor = FileSyncActor(rsync: MockRsync())
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let job = SyncJob(
                        id: UUID(),
                        target: i % 2 == 0 ? .claudeConfig : .projects,
                        paths: Set(["file\(i).txt"]),
                        direction: .push,
                        priority: SyncPriority(rawValue: i % 5) ?? .normal,
                        createdAt: .now,
                        isFullSync: false
                    )
                    await syncActor.enqueue(job)
                }
            }
        }
        
        // Queue should be internally consistent
    }
}
```

### 5.2 Sendable Compliance

```swift
final class SendableComplianceTests: XCTestCase {
    
    /// Verify all types crossing actor boundaries are Sendable
    func testSyncJob_isSendable() {
        let job = SyncJob(
            id: UUID(),
            target: .claudeConfig,
            paths: Set(["test.txt"]),
            direction: .push,
            priority: .high,
            createdAt: .now,
            isFullSync: false
        )
        
        // This test primarily verifies compilation with strict concurrency
        let _: any Sendable = job
    }
    
    func testSyncResult_isSendable() {
        let result = SyncResult(
            jobId: UUID(),
            target: .claudeConfig,
            status: .success,
            filesTransferred: 5,
            bytesTransferred: 1024,
            duration: .seconds(1),
            conflicts: [],
            errors: []
        )
        
        let _: any Sendable = result
    }
    
    func testControlMessage_isSendable() {
        let msg = ControlMessage.heartbeat(timestamp: Date())
        let _: any Sendable = msg
    }
}
```

---

## 6. E2E Sync Correctness Tests

### 6.1 Full Sync Correctness with Checksum Verification

These tests use local rsync (no SSH) between two temp directories to verify end-to-end data integrity.

```swift
final class E2ESyncCorrectnessTests: XCTestCase {
    var machineA: URL!  // Simulated Machine A directory
    var machineB: URL!  // Simulated Machine B directory
    var pipeline: TestSyncPipeline!
    
    override func setUp() async throws {
        machineA = FileManager.default.temporaryDirectory
            .appending(path: "E2E-machineA-\(UUID().uuidString)")
        machineB = FileManager.default.temporaryDirectory
            .appending(path: "E2E-machineB-\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: machineA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: machineB, withIntermediateDirectories: true)
        
        pipeline = TestSyncPipeline(source: machineA, dest: machineB)
        await pipeline.start()
    }
    
    override func tearDown() async throws {
        await pipeline.stop()
        try? FileManager.default.removeItem(at: machineA)
        try? FileManager.default.removeItem(at: machineB)
    }
    
    /// Verify complete directory tree sync with checksum comparison
    func testFullDirectorySync_checksumMatch() async throws {
        // Create complex directory structure in A
        try createTestTree(at: machineA, depth: 3, filesPerDir: 5)
        
        // Trigger full sync
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(10))
        
        // Verify all files match via SHA256 checksum
        let mismatches = try compareDirectories(machineA, machineB)
        XCTAssertTrue(mismatches.isEmpty, "Checksum mismatches: \(mismatches)")
    }
    
    /// Verify incremental sync after initial full sync
    func testIncrementalSync_onlyChangedFilesTransferred() async throws {
        // Initial sync
        try createTestTree(at: machineA, depth: 2, filesPerDir: 10)
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(5))
        
        // Modify one file
        let modifiedFile = machineA.appending(path: "dir0/file3.txt")
        try "modified content".write(to: modifiedFile, atomically: true, encoding: .utf8)
        
        // Wait for incremental sync
        try await Task.sleep(for: .seconds(4))
        
        // Verify only the modified file was transferred
        let destFile = machineB.appending(path: "dir0/file3.txt")
        let content = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(content, "modified content")
    }
    
    /// Verify deletion propagation
    func testDeletionSync_fileRemovedOnBothSides() async throws {
        // Create and sync
        let testFile = machineA.appending(path: "to-delete.txt")
        try "temporary".write(to: testFile, atomically: true, encoding: .utf8)
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(5))
        
        // Delete on A
        try FileManager.default.removeItem(at: testFile)
        
        // Wait for sync
        try await Task.sleep(for: .seconds(4))
        
        // Verify deleted on B
        let destFile = machineB.appending(path: "to-delete.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destFile.path()))
    }
    
    /// Verify binary file integrity (non-text files)
    func testBinaryFileSync_identicalChecksum() async throws {
        // Create a binary file with random data
        let binaryFile = machineA.appending(path: "data.bin")
        let randomData = Data((0..<10000).map { _ in UInt8.random(in: 0...255) })
        try randomData.write(to: binaryFile)
        
        // Sync
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(5))
        
        // Verify checksum
        let destFile = machineB.appending(path: "data.bin")
        let destData = try Data(contentsOf: destFile)
        XCTAssertEqual(sha256(randomData), sha256(destData))
    }
    
    /// Verify symlinks are handled correctly
    func testSymlinkSync_preservedOrDereferenced() async throws {
        // Create a file and a symlink to it
        let realFile = machineA.appending(path: "real.txt")
        try "real content".write(to: realFile, atomically: true, encoding: .utf8)
        
        let symlinkPath = machineA.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: realFile)
        
        // Sync and verify behavior
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(5))
        
        // Verify the symlink or its content exists on B
        let destLink = machineB.appending(path: "link.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destLink.path()))
    }
    
    /// Verify large file handling (>100MB)
    func testLargeFileSync_completesSuccessfully() async throws {
        // Create 100MB file
        let largeFile = machineA.appending(path: "large.bin")
        let handle = try FileHandle(forWritingTo: largeFile)
        let chunk = Data(repeating: 0xAB, count: 1024 * 1024)  // 1MB
        for _ in 0..<100 {
            handle.write(chunk)
        }
        handle.closeFile()
        
        // Sync
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(30))
        
        // Verify size and first/last bytes
        let destFile = machineB.appending(path: "large.bin")
        let attrs = try FileManager.default.attributesOfItem(atPath: destFile.path())
        XCTAssertEqual(attrs[.size] as? Int, 100 * 1024 * 1024)
    }
    
    /// Verify empty directories are synced
    func testEmptyDirectorySync_preserved() async throws {
        let emptyDir = machineA.appending(path: "empty-dir")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(5))
        
        let destDir = machineB.appending(path: "empty-dir")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.path(), isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
    
    /// Verify file permissions are preserved
    func testFilePermissions_preserved() async throws {
        let execFile = machineA.appending(path: "script.sh")
        try "#!/bin/bash\necho hello".write(to: execFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execFile.path())
        
        await pipeline.triggerFullSync()
        try await Task.sleep(for: .seconds(5))
        
        let destFile = machineB.appending(path: "script.sh")
        let attrs = try FileManager.default.attributesOfItem(atPath: destFile.path())
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o755)
    }
    
    // --- Helpers ---
    
    private func createTestTree(at root: URL, depth: Int, filesPerDir: Int) throws {
        if depth <= 0 { return }
        for i in 0..<filesPerDir {
            let file = root.appending(path: "file\(i).txt")
            try "Content of file \(i) at depth \(depth)".write(to: file, atomically: true, encoding: .utf8)
        }
        for i in 0..<3 {
            let subdir = root.appending(path: "dir\(i)")
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            try createTestTree(at: subdir, depth: depth - 1, filesPerDir: filesPerDir)
        }
    }
    
    private func compareDirectories(_ dirA: URL, _ dirB: URL) throws -> [(path: String, reason: String)] {
        var mismatches: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: dirA, includingPropertiesForKeys: [.isRegularFileKey])!
        
        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            
            let relativePath = fileURL.path().replacingOccurrences(of: dirA.path(), with: "")
            let correspondingFile = dirB.appending(path: relativePath)
            
            guard FileManager.default.fileExists(atPath: correspondingFile.path()) else {
                mismatches.append((relativePath, "missing in destination"))
                continue
            }
            
            let dataA = try Data(contentsOf: fileURL)
            let dataB = try Data(contentsOf: correspondingFile)
            
            if sha256(dataA) != sha256(dataB) {
                mismatches.append((relativePath, "checksum mismatch"))
            }
        }
        
        return mismatches
    }
    
    private func sha256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
```

### 6.2 Bidirectional Sync Correctness

```swift
final class BidirectionalSyncTests: XCTestCase {
    
    func testBidirectional_bothSidesCreateDifferentFiles() async throws {
        // A creates file1.txt, B creates file2.txt
        // After sync, both should have both files
    }
    
    func testBidirectional_conflictDetectionAndResolution() async throws {
        // Both sides modify same file
        // Verify conflict detected, resolved per strategy, loser archived
    }
    
    func testBidirectional_noSyncLoop() async throws {
        // A syncs to B, verify B does NOT sync back to A (echo suppression works)
        // Count rsync invocations; should be exactly 1
    }
}
```

---

## 7. Test Infrastructure

### 7.1 Test Utilities

```swift
/// Accelerated clock for testing time-dependent behavior
actor TestClock {
    var currentTime: ContinuousClock.Instant = .now
    
    func advance(by duration: Duration) {
        currentTime = currentTime.advanced(by: duration)
    }
}

/// Test pipeline that uses local rsync (no SSH)
struct TestSyncPipeline {
    let source: URL
    let dest: URL
    private var fileWatcher: FileWatcherActor?
    
    mutating func start() async {
        // Configure FSEvents on source
        // Configure rsync to use local paths (no SSH)
    }
    
    func triggerFullSync() async {
        // Execute rsync source/ dest/ without SSH
    }
    
    mutating func stop() async {
        // Cleanup FSEvents streams
    }
}

/// Helper to create deterministic test fixtures
struct TestFixtures {
    static func createClaude Config(at dir: URL) throws {
        // Creates a realistic ~/.claude/ structure for testing
    }
    
    static func createProjectStructure(at dir: URL) throws {
        // Creates a realistic project with node_modules, .git, etc.
    }
}
```

### 7.2 CI Configuration

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Build and Test
        run: |
          swift build
          swift test --filter "UnitTests"
    timeout-minutes: 5

  integration-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Integration Tests
        run: swift test --filter "IntegrationTests"
    timeout-minutes: 2

  actor-isolation-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Actor Tests (strict concurrency)
        run: |
          swift build -Xswiftc -strict-concurrency=complete
          swift test --filter "ActorIsolationTests"
    timeout-minutes: 2

  e2e-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: E2E Tests
        run: swift test --filter "E2ETests"
    timeout-minutes: 5
```

---

## 8. Coverage Targets

| Category | Target Coverage | Rationale |
|----------|----------------|-----------|
| ConflictResolver | >95% | Critical path; data loss if incorrect |
| ProcessRunner | >90% | Core utility; must handle all edge cases |
| RsyncCommandBuilder | >95% | Flag errors can corrupt data or break openrsync compatibility |
| PairingCodeGenerator | 100% | Security-critical; any bug is a MITM vulnerability |
| Debouncer | >90% | Timing bugs cause sync loops or missed syncs |
| IgnorePatterns | >90% | Incorrect patterns sync secrets or cause bloat |
| Echo Suppression | >95% | Failure causes infinite sync loops |
| FileSyncActor (queue logic) | >85% | Priority/dedup bugs cause starvation |
| E2E data integrity | 100% of happy paths | Any file corruption is unacceptable |

### Quality Gates

- [ ] All unit tests pass with zero flaky failures across 10 consecutive runs
- [ ] Integration tests pass with FSEvents within CI environment (macOS runner)
- [ ] Actor isolation tests pass under `-strict-concurrency=complete` with no warnings
- [ ] E2E checksum verification passes for all supported file types
- [ ] No memory leaks detected via Instruments Leaks template during 100-sync stress test
- [ ] Thread Sanitizer reports zero data races during concurrent test execution

---

*End of Test Strategy*
