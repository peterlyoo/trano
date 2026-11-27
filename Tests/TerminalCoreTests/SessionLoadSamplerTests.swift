import Foundation
import XCTest
@testable import TerminalCore

final class SessionLoadSamplerTests: XCTestCase {
    // Implements: FR-LOAD-1, FR-LOAD-4
    func testMachClockConversionHandlesAppleSiliconTimebaseAndOverflow() {
        XCTAssertEqual(SessionLoadClockUnits.nanoseconds(userTicks: 24_000_000, systemTicks: 0, numerator: 125, denominator: 3), 1_000_000_000)
        XCTAssertEqual(SessionLoadClockUnits.nanoseconds(userTicks: 36, systemTicks: 12, numerator: 125, denominator: 3), 2_000)
        XCTAssertEqual(SessionLoadClockUnits.nanoseconds(userTicks: UInt64.max, systemTicks: 0, numerator: 1, denominator: 1), UInt64.max)
        XCTAssertNil(SessionLoadClockUnits.nanoseconds(userTicks: UInt64.max, systemTicks: 1, numerator: 1, denominator: 1))
        XCTAssertNil(SessionLoadClockUnits.nanoseconds(userTicks: UInt64.max, systemTicks: 0, numerator: 125, denominator: 3))
        XCTAssertNil(SessionLoadClockUnits.nanoseconds(userTicks: 1, systemTicks: 0, numerator: 0, denominator: 1))
        XCTAssertNil(SessionLoadClockUnits.nanoseconds(userTicks: 1, systemTicks: 0, numerator: 1, denominator: 0))
    }

    // Implements: FR-LOAD-3, FR-LOAD-4
    func testCacheReadsAndRefreshRequestDoNotSampleSynchronously() {
        let f = Fixture()
        let sampler = f.sampler()
        sampler.requestRefresh(targets: [f.target])
        XCTAssertEqual(f.source.processCalls, 0)
        XCTAssertEqual(f.source.hookCalls, 0)
        XCTAssertEqual(f.work.count, 1)
        for _ in 0..<20 { _ = sampler.snapshots() }
        XCTAssertEqual(f.source.processCalls, 0)
        f.run()
        XCTAssertEqual(f.source.processCalls, 1)
        XCTAssertEqual(sampler.snapshots().first?.residentBytes, 100)
        let calls = f.source.processCalls
        for _ in 0..<20 { _ = sampler.snapshots() }
        XCTAssertEqual(f.source.processCalls, calls)
    }

    // Implements: FR-LOAD-3, FR-LOAD-4
    func testInflightWorkCoalescesToLatestTargetWithoutParallelCapture() {
        let f = Fixture()
        let sampler = f.sampler()
        sampler.requestRefresh(targets: [f.target])
        let replacement = SessionLoadTarget(paneID: "new", backendPID: 11, ownershipToken: "new-launch")
        sampler.requestRefresh(targets: [replacement])
        XCTAssertEqual(f.work.count, 1)
        f.run()
        XCTAssertEqual(f.source.processCalls, 1)
        XCTAssertEqual(sampler.snapshots().map(\.paneID), ["new"])
    }

    // Implements: FR-LOAD-3, FR-LOAD-4
    func testCPURefreshAndHookRefreshUseIndependentCooldowns() {
        let f = Fixture()
        let sampler = f.sampler()
        for tick in [0.0, 0.5, 1.9, 2, 4, 29.9, 30, 32] {
            f.tick = tick
            sampler.requestRefresh(targets: [f.target])
            f.run()
        }
        XCTAssertEqual(f.source.processCalls, 5)
        XCTAssertEqual(f.source.hookCalls, 2)
        XCTAssertTrue(f.source.lastHookTargets.allSatisfy { $0.provider == .claude })
    }

    // Implements: FR-LOAD-3, FR-LOAD-4
    func testHookSourceCountIsBoundedAndNonClaudeSourcesAreExcluded() {
        let f = Fixture()
        let sampler = f.sampler()
        let targets = (0..<25).map { SessionLoadTarget(paneID: "pane-\($0)", backendPID: Int32(100 + $0), ownershipToken: "generation", provider: .claude, providerSessionID: "provider-\($0)") }
            + [SessionLoadTarget(paneID: "codex", backendPID: 200, ownershipToken: "codex", provider: .codex, providerSessionID: "codex-provider")]
        sampler.requestRefresh(targets: targets)
        f.run()
        XCTAssertEqual(f.source.lastHookTargets.count, 16)
        XCTAssertTrue(f.source.lastHookTargets.allSatisfy { $0.provider == .claude })
    }

    // Implements: FR-LOAD-3, FR-LOAD-4
    func testStopCancelsQueuedCollectionAndCacheReadersStillDoNoWork() {
        let f = Fixture()
        let sampler = f.sampler()
        sampler.requestRefresh(targets: [f.target])
        XCTAssertEqual(f.work.count, 1)
        sampler.stop()
        f.run()
        XCTAssertEqual(f.source.processCalls, 0)
        XCTAssertTrue(sampler.snapshots().isEmpty)
        sampler.requestRefresh(targets: [f.target])
        f.run()
        XCTAssertEqual(f.source.processCalls, 0)
    }

    private final class Source: SessionLoadSource {
        var processCalls = 0
        var hookCalls = 0
        var lastHookTargets: [SessionLoadTarget] = []
        func processes(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> SessionLoadBatch {
            processCalls += 1
            return SessionLoadBatch(processes: [SessionLoadProcess(pid: 10, parentPID: 1, userID: 501,
                startedAtMicroseconds: 900_000_000, cpuNanoseconds: UInt64(processCalls) * 1_000_000, residentBytes: 100),
                SessionLoadProcess(pid: 11, parentPID: 1, userID: 501, startedAtMicroseconds: 900_000_000,
                    cpuNanoseconds: 0, residentBytes: 200)], userID: 501, observedAt: moment.date, monotonicSeconds: moment.monotonicSeconds)
        }
        func hookTails(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> [SessionHookTail]? {
            hookCalls += 1; lastHookTargets = targets
            return []
        }
    }

    private final class Fixture {
        let source = Source()
        let target = SessionLoadTarget(paneID: "one", backendPID: 10, ownershipToken: "launch-one", provider: .claude, providerSessionID: "provider-one")
        var tick = 0.0
        var work: [() -> Void] = []
        func sampler() -> SessionLoadSampler {
            SessionLoadSampler(source: source, schedule: { self.work.append($0) }, clock: {
                SessionLoadMoment(date: Date(timeIntervalSince1970: 1_000 + self.tick), monotonicSeconds: self.tick)
            })
        }
        func run() { let pending = work; work = []; for action in pending { action() } }
    }
}
