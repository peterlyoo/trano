import Foundation
import TerminalCore
import XCTest
@testable import TranoApp

final class SessionLoadClientCacheTests: XCTestCase {
    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    @MainActor func testMemoryReadsNeverFetchAndRefreshCoalescesBackgroundWork() {
        var work: [() -> Void] = []
        var calls = 0
        let snapshot = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available, cpuPercent: 15,
            residentBytes: 24, observedAt: Date(timeIntervalSince1970: 1000))
        let cache = SessionLoadClientCache(fetch: { calls += 1; return [snapshot] }, schedule: { work.append($0) }, deliver: { $0() },
            clock: { Date(timeIntervalSince1970: 1000) })
        for _ in 0..<20 { _ = cache.byPane["pane"] }
        XCTAssertEqual(calls, 0)
        cache.refresh(); cache.refresh()
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(calls, 0)
        for action in work { action() }
        XCTAssertEqual(cache.byPane["pane"]?.residentBytes, 24)
        XCTAssertEqual(calls, 1)
        for _ in 0..<20 { _ = cache.byPane["pane"] }
        XCTAssertEqual(calls, 1)
    }

    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    @MainActor func testFetchFailureCannotKeepOldResourceOrHookValuesLive() throws {
        let base = Date(timeIntervalSince1970: 1000)
        var now = base
        var work: [() -> Void] = []
        let snapshot = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available, cpuPercent: 25,
            residentBytes: 24, observedAt: base,
            hook: SessionHookLatency(p99Milliseconds: 17, sampleCount: 1, status: .available, observedAt: base, latestEventAt: base))
        let cache = SessionLoadClientCache(initial: [snapshot], fetch: { throw NSError(domain: "offline", code: 1) },
            schedule: { work.append($0) }, deliver: { $0() }, clock: { now })
        now = base.addingTimeInterval(7)
        cache.refresh()
        let stale = try XCTUnwrap(cache.byPane["pane"])
        XCTAssertEqual(stale.status, .stale)
        XCTAssertNil(stale.cpuPercent)
        XCTAssertNil(stale.residentBytes)
        XCTAssertEqual(stale.hook.p99Milliseconds, 17)
        for action in work { action() }
        now = base.addingTimeInterval(66)
        cache.refresh()
        let expired = try XCTUnwrap(cache.byPane["pane"])
        XCTAssertEqual(expired.hook.status, .stale)
        XCTAssertNil(expired.hook.p99Milliseconds)
    }
}
