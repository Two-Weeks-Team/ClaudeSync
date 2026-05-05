import XCTest
@testable import ClaudeSync

final class DebouncerTests: XCTestCase {

    /// Use millisecond budgets so the tests stay fast.
    private func makeStream() -> (AsyncStream<Debouncer.Output>, Debouncer) {
        Debouncer.makeStream(
            quietPeriod: .milliseconds(80),
            coalesceDelay: .milliseconds(20)
        )
    }

    func testSingleEvent_firesAfterQuietPeriod() async throws {
        let (stream, deb) = makeStream()
        await deb.addPaths(["a.txt"], for: .claudeConfig)

        let received = await Self.firstEvent(from: stream, deadline: .seconds(1))
        XCTAssertEqual(received?.target, .claudeConfig)
        XCTAssertEqual(received?.paths, ["a.txt"])
    }

    func testRapidEvents_resetTimer_andOnlyEmitOnce() async throws {
        let (stream, deb) = makeStream()
        await deb.addPaths(["a.txt"], for: .claudeConfig)
        try await Task.sleep(for: .milliseconds(40))
        await deb.addPaths(["a.txt"], for: .claudeConfig)
        try await Task.sleep(for: .milliseconds(40))
        await deb.addPaths(["a.txt"], for: .claudeConfig)

        let received = await Self.firstEvent(from: stream, deadline: .seconds(1))
        XCTAssertEqual(received?.paths, ["a.txt"])

        // No second event should follow within a generous window.
        let second = await Self.firstEvent(from: stream, deadline: .milliseconds(150))
        XCTAssertNil(second, "Same-path events must coalesce into one emission")
    }

    func testIndependentPaths_haveIndependentTimers() async throws {
        let (stream, deb) = makeStream()
        // Schedule two events at different times; both should be flushed in
        // the SAME emission because they end up in the ready set close enough
        // together to land within the 20ms coalesce window.
        await deb.addPaths(["a.txt"], for: .claudeConfig)
        await deb.addPaths(["b.txt"], for: .claudeConfig)

        let first = await Self.firstEvent(from: stream, deadline: .seconds(1))
        XCTAssertEqual(first?.paths, ["a.txt", "b.txt"])
    }

    func testDifferentTargets_emitSeparately() async throws {
        let (stream, deb) = makeStream()
        await deb.addPaths(["x"], for: .claudeConfig)
        await deb.addPaths(["y"], for: .codexConfig)

        let collected = await Self.collect(from: stream, count: 2, deadline: .seconds(2))
        XCTAssertEqual(collected.count, 2)
        let byTarget = Dictionary(uniqueKeysWithValues: collected.map { ($0.target, $0.paths) })
        XCTAssertEqual(byTarget[.claudeConfig], ["x"])
        XCTAssertEqual(byTarget[.codexConfig],  ["y"])
    }

    func testCancelAll_drainsWithoutEmitting() async throws {
        let (stream, deb) = makeStream()
        await deb.addPaths(["a", "b", "c"], for: .claudeConfig)
        await deb.cancelAll()

        let received = await Self.firstEvent(from: stream, deadline: .milliseconds(200))
        XCTAssertNil(received)
        let pending = await deb.pendingPathCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Helpers

    static func firstEvent(
        from stream: AsyncStream<Debouncer.Output>,
        deadline: Duration
    ) async -> Debouncer.Output? {
        await withTaskGroup(of: Debouncer.Output?.self) { group in
            group.addTask {
                for await ev in stream { return ev }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r
        }
    }

    static func collect(
        from stream: AsyncStream<Debouncer.Output>,
        count: Int,
        deadline: Duration
    ) async -> [Debouncer.Output] {
        await withTaskGroup(of: [Debouncer.Output].self) { group in
            group.addTask {
                var out: [Debouncer.Output] = []
                for await ev in stream {
                    out.append(ev)
                    if out.count >= count { break }
                }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return []
            }
            let r = await group.next() ?? []
            group.cancelAll()
            return r
        }
    }
}
