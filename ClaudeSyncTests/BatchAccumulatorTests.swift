import XCTest
@testable import ClaudeSync

final class BatchAccumulatorTests: XCTestCase {

    func testAccumulate_thenFlushTimer_emitsOnce() async throws {
        let (stream, acc) = BatchAccumulator.makeStream(flushInterval: .milliseconds(100))
        let consumer = Task<[BatchAccumulator.Output], Never> {
            var out: [BatchAccumulator.Output] = []
            for await batch in stream {
                out.append(batch)
                if out.count >= 1 { break }
            }
            return out
        }

        await acc.accumulate(paths: ["a", "b"], for: .claudeConfig)
        await acc.accumulate(paths: ["c"], for: .claudeConfig)

        try await Task.sleep(for: .milliseconds(250))
        await acc.close()

        let batches = await consumer.value
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.target, .claudeConfig)
        XCTAssertEqual(batches.first?.paths, ["a", "b", "c"])
    }

    func testFlushImmediately_emitsBeforeTimer() async throws {
        let (stream, acc) = BatchAccumulator.makeStream(flushInterval: .seconds(60))
        let consumer = Task<[BatchAccumulator.Output], Never> {
            var out: [BatchAccumulator.Output] = []
            for await batch in stream {
                out.append(batch)
                if out.count >= 1 { break }
            }
            return out
        }

        await acc.accumulate(paths: ["x"], for: .codexConfig)
        await acc.flushImmediately()

        try await Task.sleep(for: .milliseconds(50))
        await acc.close()

        let batches = await consumer.value
        XCTAssertEqual(batches.first?.paths, ["x"])
    }

    func testCancelAll_dropsPending() async throws {
        let (stream, acc) = BatchAccumulator.makeStream(flushInterval: .milliseconds(80))
        await acc.accumulate(paths: ["lost"], for: .codexConfig)
        await acc.cancelAll()

        // After cancelAll, the timer is dropped. Wait beyond the original
        // interval and verify no event arrives, then close to terminate.
        try await Task.sleep(for: .milliseconds(150))
        await acc.close()

        var got = 0
        for await _ in stream { got += 1 }
        XCTAssertEqual(got, 0)
    }

    func testMultipleTargets_emittedAsSeparateBatches() async throws {
        let (stream, acc) = BatchAccumulator.makeStream(flushInterval: .milliseconds(60))
        let consumer = Task<[BatchAccumulator.Output], Never> {
            var out: [BatchAccumulator.Output] = []
            for await batch in stream {
                out.append(batch)
                if out.count >= 2 { break }
            }
            return out
        }

        await acc.accumulate(paths: ["a"], for: .claudeConfig)
        await acc.accumulate(paths: ["b"], for: .codexConfig)

        try await Task.sleep(for: .milliseconds(200))
        await acc.close()

        let batches = await consumer.value
        XCTAssertEqual(batches.count, 2)
        let byTarget = Dictionary(uniqueKeysWithValues: batches.map { ($0.target, $0.paths) })
        XCTAssertEqual(byTarget[.claudeConfig], ["a"])
        XCTAssertEqual(byTarget[.codexConfig],  ["b"])
    }
}
