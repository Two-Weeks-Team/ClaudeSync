import XCTest
@testable import ClaudeSync

final class SyncHistoryTests: XCTestCase {
    var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testRecord_thenReadBack() async {
        let history = SyncHistory(homeDirectory: tempHome)
        let result = SyncResult(
            jobId: UUID(), target: .claudeConfig, status: .success,
            filesTransferred: 3, bytesTransferred: 1024, duration: .milliseconds(250)
        )
        await history.record(result, direction: .push)

        let recent = await history.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.target, .claudeConfig)
        XCTAssertEqual(recent.first?.status, .success)
        XCTAssertEqual(recent.first?.filesTransferred, 3)
    }

    func testPersistence_survivesReinstantiation() async throws {
        let h1 = SyncHistory(homeDirectory: tempHome)
        let r = SyncResult(jobId: UUID(), target: .codexConfig, status: .success)
        await h1.record(r, direction: .push)

        // Build a fresh actor against the same home dir → must read history.json
        let h2 = SyncHistory(homeDirectory: tempHome)
        let recent = await h2.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.target, .codexConfig)
    }

    func testRecord_capsAtMaxEntries() async {
        let history = SyncHistory(homeDirectory: tempHome, maxEntries: 5)
        for i in 0..<10 {
            let r = SyncResult(
                jobId: UUID(), target: .claudeConfig, status: .success,
                filesTransferred: i
            )
            await history.record(r, direction: .push)
        }
        let recent = await history.recent()
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first?.filesTransferred, 9, "Newest entries kept")
        XCTAssertEqual(recent.last?.filesTransferred, 5)
    }

    func testStatusCodeMapping_propagatesAllCases() async {
        let history = SyncHistory(homeDirectory: tempHome)
        let cases: [(SyncResult.ResultStatus, SyncHistory.Entry.StatusCode)] = [
            (.success, .success),
            (.partialSuccess(transferredCount: 1, failedCount: 1), .partialSuccess),
            (.failure(reason: "x"), .failure),
            (.cancelled, .cancelled),
        ]
        for (input, expected) in cases {
            let r = SyncResult(jobId: UUID(), target: .codexConfig, status: input)
            await history.record(r, direction: .push)
            let recent = await history.recent(limit: 1)
            XCTAssertEqual(recent.first?.status, expected)
        }
    }

    func testClear_removesEverything() async {
        let history = SyncHistory(homeDirectory: tempHome)
        let r = SyncResult(jobId: UUID(), target: .claudeConfig, status: .success)
        await history.record(r, direction: .push)
        await history.clear()
        let recent = await history.recent()
        XCTAssertEqual(recent.count, 0)
    }
}
