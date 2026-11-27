import Foundation
import XCTest
@testable import TerminalCore

final class SessionLoadTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000)
    private let uid: UInt32 = 501

    // Implements: FR-LOAD-1, FR-LOAD-2
    func testLiveDescendantCPUAndMemoryExcludeUnrelatedAndForeignProcesses() throws {
        var engine = SessionLoadEngine()
        let target = target("one", pid: 10)
        let first = batch([process(10, cpu: 1_000_000_000, memory: 100), process(20, parent: 10, cpu: 500_000_000, memory: 200),
                           process(30, cpu: 9_000_000_000, memory: 900), process(40, parent: 10, user: 502, cpu: 9_000_000_000, memory: 900)])
        let warm = try row(engine.ingest(targets: [target], batch: first, now: base))
        XCTAssertNil(warm.cpuPercent)
        XCTAssertEqual(warm.residentBytes, 300)
        XCTAssertEqual(warm.processCount, 2)
        let next = batch([process(10, cpu: 2_000_000_000, memory: 110), process(20, parent: 10, cpu: 1_000_000_000, memory: 220),
                          process(30, cpu: 99_000_000_000, memory: 999), process(40, parent: 10, user: 502, cpu: 99_000_000_000, memory: 999)], tick: 2)
        let value = try row(engine.ingest(targets: [target], batch: next, now: base.addingTimeInterval(1)))
        XCTAssertEqual(try XCTUnwrap(value.cpuPercent), 150, accuracy: 0.001)
        XCTAssertEqual(value.residentBytes, 330)
        XCTAssertEqual(value.status, .available)
    }

    // Implements: FR-LOAD-2
    func testPIDReuseWithoutNewOwnershipTokenCannotInheritOrRebindMetrics() throws {
        var engine = SessionLoadEngine()
        let original = target("one", pid: 10)
        _ = engine.ingest(targets: [original], batch: batch([process(10, cpu: 10, memory: 100)]), now: base)
        let reused = batch([process(10, start: 950_000_000, cpu: 900, memory: 900)], tick: 2)
        let rejected = try row(engine.ingest(targets: [original], batch: reused, now: base.addingTimeInterval(1)))
        XCTAssertEqual(rejected.status, .unavailable)
        XCTAssertNil(rejected.cpuPercent)
        XCTAssertNil(rejected.residentBytes)
        XCTAssertTrue(rejected.history.isEmpty)
        let replacement = target("one", pid: 10, token: "launch-two")
        let fresh = try row(engine.ingest(targets: [replacement], batch: reused, now: base.addingTimeInterval(1)))
        XCTAssertEqual(fresh.status, .warmingUp)
        XCTAssertNil(fresh.cpuPercent)
        XCTAssertEqual(fresh.residentBytes, 900)
    }

    // Implements: FR-LOAD-2
    func testNearestRootOwnsNestedProcessesAndInvalidAncestryIsExcluded() throws {
        var engine = SessionLoadEngine()
        let processes = [process(10, memory: 10), process(20, parent: 10, start: 910_000_000, memory: 20),
                         process(30, parent: 10, start: 920_000_000, memory: 30), process(40, parent: 30, start: 930_000_000, memory: 40),
                         process(50, parent: 60, memory: 50), process(60, parent: 50, memory: 60),
                         process(70, parent: 20, start: 905_000_000, memory: 70)]
        let rows = engine.ingest(targets: [target("outer", pid: 10), target("inner", pid: 30)], batch: batch(processes), now: base)
        XCTAssertEqual(try row(rows, id: "outer").residentBytes, 30)
        XCTAssertEqual(try row(rows, id: "inner").residentBytes, 70)
        XCTAssertEqual(rows.reduce(0) { $0 + ($1.residentBytes ?? 0) }, 100)
    }

    // Implements: FR-LOAD-1, FR-LOAD-2
    func testMissingPartialRemoteAndStoppedAreUnknownRatherThanZero() throws {
        for complete in [true, false] {
            var engine = SessionLoadEngine()
            let rows = engine.ingest(targets: [target("one", pid: 10)], batch: batch(complete ? [] : [process(10)], complete: complete), now: base)
            let value = try row(rows)
            XCTAssertEqual(value.status, .unavailable)
            XCTAssertNil(value.cpuPercent)
            XCTAssertNil(value.residentBytes)
        }
        var engine = SessionLoadEngine()
        let rows = engine.ingest(targets: [target("remote", pid: 10, local: false), target("dead", pid: 11, alive: false)], batch: batch([process(10), process(11)]), now: base)
        XCTAssertEqual(try row(rows, id: "remote").status, .remoteUnavailable)
        XCTAssertEqual(try row(rows, id: "dead").status, .stopped)
        XCTAssertTrue(rows.allSatisfy { $0.cpuPercent == nil && $0.residentBytes == nil })
    }

    // Implements: FR-LOAD-1
    func testCounterRegressionCannotBecomeAnIdleZeroAndHistoryIsBounded() throws {
        var engine = SessionLoadEngine()
        let owner = target("one", pid: 10)
        _ = engine.ingest(targets: [owner], batch: batch([process(10, cpu: 100, memory: 10)]), now: base)
        let reset = try row(engine.ingest(targets: [owner], batch: batch([process(10, cpu: 10, memory: 20)], tick: 2), now: base.addingTimeInterval(1)))
        XCTAssertNil(reset.cpuPercent)
        XCTAssertEqual(reset.residentBytes, 20)
        for tick in 3...80 {
            _ = engine.ingest(targets: [owner], batch: batch([process(10, cpu: UInt64(tick) * 1_000_000, memory: 20)], tick: Double(tick)), now: base.addingTimeInterval(Double(tick - 1)))
        }
        let latest = try XCTUnwrap(engine.cached(paneID: owner.paneID, now: base.addingTimeInterval(79)))
        XCTAssertEqual(latest.history.count, 60)
        XCTAssertTrue(latest.cpuPercent?.isFinite == true)
    }

    // Implements: FR-LOAD-1, FR-LOAD-3
    func testCachedResourceAndHookFreshnessRemainIndependent() throws {
        var engine = SessionLoadEngine()
        let owner = target("one", pid: 10, provider: .claude, providerSessionID: "provider-one")
        let tail = SessionHookTail(paneID: "one", ownershipToken: "launch-one", providerSessionID: "provider-one", collectedAt: base,
                                  bytes: summary([25], at: base))
        _ = engine.ingest(targets: [owner], batch: batch([process(10, memory: 1)]), hookTails: [tail], now: base)
        let staleCPU = try XCTUnwrap(engine.cached(paneID: "one", now: base.addingTimeInterval(7)))
        XCTAssertEqual(staleCPU.status, .stale)
        XCTAssertNil(staleCPU.cpuPercent)
        XCTAssertNil(staleCPU.residentBytes)
        XCTAssertEqual(staleCPU.hook.p99Milliseconds, 25)
        XCTAssertEqual(staleCPU.hook.status, .available)
        let staleHook = try XCTUnwrap(engine.cached(paneID: "one", now: base.addingTimeInterval(66)))
        XCTAssertEqual(staleHook.hook.status, .stale)
        XCTAssertNil(staleHook.hook.p99Milliseconds)
    }

    // Implements: FR-LOAD-1, FR-LOAD-4
    func testClaudeStopHookP99UsesOnlyIndividualNumericDurationsAndExactOwner() throws {
        let owner = target("one", pid: 10, provider: .claude, providerSessionID: "provider-one")
        var bytes = summary(Array(1...100).map(Double.init), at: base)
        bytes += Data("{\"type\":\"system\",\"subtype\":\"turn_duration\",\"timestamp\":\"1970-01-01T00:16:40Z\",\"durationMs\":99999}\n".utf8)
        bytes += summary([true, -1, "1000", 1000], at: base.addingTimeInterval(-1801))
        bytes += summary([99999], at: base.addingTimeInterval(1))
        bytes += summary([true, -1, "1000"], at: base)
        let tail = SessionHookTail(paneID: "one", ownershipToken: "launch-one", providerSessionID: "provider-one", collectedAt: base, bytes: bytes)
        let result = SessionHookLatencyParser.summarize(target: owner, tails: [tail], now: base)
        XCTAssertEqual(result.p99Milliseconds, 99)
        XCTAssertEqual(result.sampleCount, 100)
        XCTAssertEqual(result.windowSeconds, 1800)
        XCTAssertEqual(result.scope, "individual_claude_stop_hook")
        for wrong in [SessionHookTail(paneID: "different", ownershipToken: "launch-one", providerSessionID: "provider-one", collectedAt: base, bytes: bytes),
                      SessionHookTail(paneID: "one", ownershipToken: "old-launch", providerSessionID: "provider-one", collectedAt: base, bytes: bytes),
                      SessionHookTail(paneID: "one", ownershipToken: "launch-one", providerSessionID: "different", collectedAt: base, bytes: bytes)] {
            XCTAssertNil(SessionHookLatencyParser.summarize(target: owner, tails: [wrong], now: base).p99Milliseconds)
        }
        XCTAssertNil(SessionHookLatencyParser.summarize(target: target("one", pid: 10, provider: .codex, providerSessionID: "provider-one"), tails: [tail], now: base).p99Milliseconds)
    }

    // Implements: FR-LOAD-1, FR-LOAD-4
    func testTailParserDropsPartialLinesAndRejectsEmbeddedSessionMismatch() {
        let owner = target("one", pid: 10, provider: .claude, providerSessionID: "provider-one")
        var bytes = Data("partial prefix\n".utf8)
        bytes += summary([42], at: base)
        bytes += summary([999], at: base, extra: ["sessionId": "wrong-session"])
        bytes += Data("{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"hookInfos\":[{\"durationMs\":99999}]".utf8)
        let tail = SessionHookTail(paneID: "one", ownershipToken: "launch-one", providerSessionID: "provider-one", collectedAt: base, fileOffset: 20, bytes: bytes)
        let value = SessionHookLatencyParser.summarize(target: owner, tails: [tail], now: base)
        XCTAssertEqual(value.sampleCount, 1)
        XCTAssertEqual(value.p99Milliseconds, 42)
        XCTAssertFalse(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self).contains("hookInfos"))
    }

    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testProviderOutsideVerifiedBackendCannotContributeHookTelemetry() throws {
        var engine = SessionLoadEngine()
        let owner = SessionLoadTarget(paneID: "one", backendPID: 10, ownershipToken: "launch-one",
            provider: .claude, providerSessionID: "provider-one", providerPID: 50)
        let tail = SessionHookTail(paneID: "one", ownershipToken: "launch-one", providerSessionID: "provider-one",
            collectedAt: base, bytes: summary([999], at: base))
        let outside = try row(engine.ingest(targets: [owner], batch: batch([process(10), process(50)]), hookTails: [tail], now: base))
        XCTAssertNil(outside.hook.p99Milliseconds)
        let inside = try row(engine.ingest(targets: [owner], batch: batch([process(10), process(50, parent: 10)], tick: 2),
            hookTails: [tail], now: base.addingTimeInterval(1)))
        XCTAssertEqual(inside.hook.p99Milliseconds, 999)
    }

    private func target(_ id: String, pid: Int32, token: String = "launch-one", provider: AgentKind = .shell,
                        providerSessionID: String? = nil, alive: Bool = true, local: Bool = true) -> SessionLoadTarget {
        SessionLoadTarget(paneID: id, backendPID: pid, ownershipToken: token, provider: provider,
                          providerSessionID: providerSessionID, alive: alive, local: local)
    }
    private func process(_ pid: Int32, parent: Int32 = 1, user: UInt32? = nil, start: UInt64 = 900_000_000,
                         cpu: UInt64 = 0, memory: UInt64 = 0) -> SessionLoadProcess {
        SessionLoadProcess(pid: pid, parentPID: parent, userID: user ?? uid, startedAtMicroseconds: start,
                           cpuNanoseconds: cpu, residentBytes: memory)
    }
    private func batch(_ processes: [SessionLoadProcess], tick: Double = 1, complete: Bool = true) -> SessionLoadBatch {
        SessionLoadBatch(processes: processes, userID: uid, observedAt: base.addingTimeInterval(tick - 1), monotonicSeconds: tick, complete: complete)
    }
    private func row(_ rows: [SessionLoadSnapshot], id: String = "one", file: StaticString = #filePath, line: UInt = #line) throws -> SessionLoadSnapshot {
        try XCTUnwrap(rows.first { $0.paneID == id }, file: file, line: line)
    }
    private func summary(_ durations: [Any], at date: Date, extra: [String: Any] = [:]) -> Data {
        var object = extra
        object["type"] = "system"; object["subtype"] = "stop_hook_summary"
        object["timestamp"] = ISO8601DateFormatter().string(from: date)
        object["hookInfos"] = durations.map { ["durationMs": $0] }
        var result = try! JSONSerialization.data(withJSONObject: object)
        result.append(10)
        return result
    }
}
