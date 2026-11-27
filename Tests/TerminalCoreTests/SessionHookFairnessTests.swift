import Darwin
import Foundation
import XCTest
@testable import TerminalCore

final class SessionHookFairnessTests: XCTestCase {
    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testEveryStableBindingIsReadWithinBoundedRoundsDespiteReordering() {
        let fixture = Fixture(count: 35)
        let sampler = fixture.sampler()
        for tick in [0.0, 30, 60] {
            fixture.tick = tick
            sampler.requestRefresh(targets: tick == 30 ? Array(fixture.targets.reversed()) : fixture.targets)
            fixture.run()
        }
        XCTAssertEqual(fixture.source.reads.count, 3)
        XCTAssertTrue(fixture.source.reads.allSatisfy { $0.count <= 16 })
        XCTAssertEqual(Set(fixture.source.reads.flatMap { $0.map(\.paneID) }), Set(fixture.targets.map(\.paneID)))
        XCTAssertEqual(fixture.source.processCalls, 3)
        XCTAssertEqual(sampler.snapshots().filter { $0.hook.p99Milliseconds != nil }.count, 35)
    }

    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-3
    func testUnselectedHookSamplesKeepOriginalTimestampAndBecomeTruthfullyStale() throws {
        let fixture = Fixture(count: 48)
        let sampler = fixture.sampler()
        sampler.requestRefresh(targets: fixture.targets)
        fixture.run()
        let original = try XCTUnwrap(sampler.snapshots().first { $0.paneID == "pane-0" })
        XCTAssertEqual(original.hook.status, .available)
        XCTAssertEqual(original.hook.observedAt, fixture.base)
        for tick in [30.0, 60] {
            fixture.tick = tick
            sampler.requestRefresh(targets: fixture.targets)
            fixture.run()
            let preserved = try XCTUnwrap(sampler.snapshots().first { $0.paneID == "pane-0" })
            XCTAssertEqual(preserved.hook.p99Milliseconds, original.hook.p99Milliseconds)
            XCTAssertEqual(preserved.hook.observedAt, fixture.base)
        }
        fixture.tick = 66
        let stale = try XCTUnwrap(sampler.snapshots().first { $0.paneID == "pane-0" })
        XCTAssertEqual(stale.hook.status, .stale)
        XCTAssertNil(stale.hook.p99Milliseconds)
        XCTAssertEqual(stale.hook.observedAt, fixture.base)
        XCTAssertEqual(fixture.source.reads.count, 3)
    }

    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testRemovedAndReplacedBindingsCannotKeepOldHookCacheOrSchedulingIdentity() throws {
        let fixture = Fixture(count: 32)
        let sampler = fixture.sampler()
        sampler.requestRefresh(targets: fixture.targets)
        fixture.run()
        let old = fixture.targets[0]
        let replacement = SessionLoadTarget(paneID: old.paneID, backendPID: old.backendPID,
            ownershipToken: "replacement", provider: .claude, providerSessionID: UUID().uuidString,
            providerPID: old.providerPID, hookBindingToken: "replacement-generation")
        fixture.targets[0] = replacement
        fixture.targets.removeAll { $0.paneID == "pane-1" }
        fixture.tick = 2
        sampler.requestRefresh(targets: fixture.targets)
        fixture.run()
        let replaced = try XCTUnwrap(sampler.snapshots().first { $0.paneID == old.paneID })
        XCTAssertEqual(replaced.hook.status, .unavailable)
        XCTAssertNil(replaced.hook.p99Milliseconds)
        XCTAssertNil(replaced.hook.observedAt)
        XCTAssertFalse(sampler.snapshots().contains { $0.paneID == "pane-1" })
        for tick in [30.0, 60] {
            fixture.tick = tick
            sampler.requestRefresh(targets: fixture.targets)
            fixture.run()
        }
        let later = fixture.source.reads.dropFirst().flatMap { $0 }
        XCTAssertFalse(later.contains { $0.paneID == "pane-1" })
        XCTAssertFalse(later.contains { $0 == old })
        XCTAssertTrue(later.contains(replacement))
        XCTAssertTrue(fixture.source.reads.allSatisfy { $0.count <= 16 })
    }

    // Implements: FR-LOAD-1, FR-LOAD-2
    func testSameTokenKernelPIDReuseCannotRetainOrReacquireHookLatency() throws {
        let fixture = Fixture(count: 1)
        let sampler = fixture.sampler()
        sampler.requestRefresh(targets: fixture.targets)
        fixture.run()
        XCTAssertNotNil(sampler.snapshots().first?.hook.p99Milliseconds)
        fixture.source.births[fixture.targets[0].backendPID] = 999_000_000
        for tick in [2.0, 30] {
            fixture.tick = tick
            sampler.requestRefresh(targets: fixture.targets)
            fixture.run()
            let rejected = try XCTUnwrap(sampler.snapshots().first)
            XCTAssertEqual(rejected.status, .unavailable)
            XCTAssertEqual(rejected.hook.status, .unavailable)
            XCTAssertNil(rejected.hook.p99Milliseconds)
        }
    }

    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testMissingSelectedHookClearsOnlyThatBindingWithoutZeroOrRefreshedOldSamples() throws {
        let fixture = Fixture(count: 32)
        let sampler = fixture.sampler()
        for tick in [0.0, 30] {
            fixture.tick = tick
            sampler.requestRefresh(targets: fixture.targets)
            fixture.run()
        }
        fixture.source.missing.insert("pane-0")
        fixture.tick = 60
        sampler.requestRefresh(targets: fixture.targets)
        fixture.run()
        let missing = try XCTUnwrap(sampler.snapshots().first { $0.paneID == "pane-0" })
        XCTAssertEqual(missing.hook.status, .unavailable)
        XCTAssertNil(missing.hook.p99Milliseconds)
        let retained = try XCTUnwrap(sampler.snapshots().first { $0.paneID == "pane-16" })
        XCTAssertEqual(retained.hook.status, .available)
        XCTAssertEqual(retained.hook.observedAt, fixture.base.addingTimeInterval(30))
        XCTAssertNotNil(retained.hook.p99Milliseconds)
    }

    // Implements: FR-LOAD-1, FR-LOAD-2, FR-LOAD-4
    func testSyntheticFileReaderVisitsEveryBindingWithoutIncreasingFileOrByteBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture(count: 33)
        var reads: [(String, Int)] = []
        for target in fixture.targets {
            try Self.summary(at: fixture.base).write(to: directory.appendingPathComponent(target.providerSessionID! + ".jsonl"))
        }
        let source = SessionLoadNativeSource(userID: 501,
            listPIDs: { _ in SessionLoadPIDList(pids: fixture.targets.map(\.backendPID)) },
            readProcess: { pid in SessionLoadProcess(pid: pid, parentPID: 1, userID: 501,
                startedAtMicroseconds: 900_000_000, cpuNanoseconds: 0, residentBytes: 100) },
            readHook: { target, moment, limit in
                reads.append((target.paneID, limit))
                let binding = SessionHookFileBinding(paneID: target.paneID, ownershipToken: target.ownershipToken,
                    providerSessionID: target.providerSessionID!, configurationRoot: directory.path,
                    relativePath: target.providerSessionID! + ".jsonl")
                return SessionHookFileReader.tail(binding: binding, target: target, at: moment, limit: limit)
            })
        let targets = fixture.targets.map {
            SessionLoadTarget(paneID: $0.paneID, backendPID: $0.backendPID, ownershipToken: $0.ownershipToken,
                provider: .claude, providerSessionID: $0.providerSessionID)
        }
        let sampler = fixture.sampler(source: source)
        for tick in [0.0, 30, 60] {
            let before = reads.count
            fixture.tick = tick
            sampler.requestRefresh(targets: targets)
            fixture.run()
            XCTAssertLessThanOrEqual(reads.count - before, 16)
        }
        XCTAssertEqual(Set(reads.map(\.0)), Set(targets.map(\.paneID)))
        XCTAssertTrue(reads.allSatisfy { $0.1 == 262_144 })
        XCTAssertEqual(sampler.snapshots().filter { $0.hook.p99Milliseconds != nil }.count, 33)
    }

    // Implements: FR-LOAD-2, FR-LOAD-3, FR-LOAD-4
    func testTargetChangeDuringCollectionCannotSpendAnotherHookBudgetBeforeThirtySeconds() {
        let fixture = Fixture(count: 35)
        let sampler = fixture.sampler()
        let reordered = Array(fixture.targets.reversed())
        fixture.source.duringProcesses = { sampler.requestRefresh(targets: reordered) }
        sampler.requestRefresh(targets: fixture.targets)
        fixture.run()
        fixture.run()
        XCTAssertEqual(fixture.source.processCalls, 2)
        XCTAssertEqual(fixture.source.reads.flatMap { $0 }.count, 16)
        fixture.tick = 29
        sampler.requestRefresh(targets: reordered)
        fixture.run()
        XCTAssertEqual(fixture.source.reads.flatMap { $0 }.count, 16)
        for tick in [31.0, 61] {
            fixture.tick = tick
            sampler.requestRefresh(targets: reordered)
            fixture.run()
        }
        XCTAssertEqual(fixture.source.reads.count, 3)
        XCTAssertEqual(Set(fixture.source.reads.flatMap { $0.map(\.paneID) }), Set(fixture.targets.map(\.paneID)))
    }

    // Implements: FR-LOAD-2, FR-LOAD-3
    func testAmbiguousTargetsRevokeNumericCacheBeforeQueuedCollection() {
        let fixture = Fixture(count: 1)
        let sampler = fixture.sampler()
        let original = fixture.targets[0]
        sampler.requestRefresh(targets: [original])
        fixture.run()
        XCTAssertEqual(sampler.snapshots().count, 1)
        let conflict = SessionLoadTarget(paneID: original.paneID, backendPID: 999, ownershipToken: "conflict",
            provider: .claude, providerSessionID: UUID().uuidString)
        sampler.requestRefresh(targets: [original, conflict])
        XCTAssertTrue(sampler.snapshots().isEmpty)
        sampler.requestRefresh(targets: [original, original])
        XCTAssertTrue(sampler.snapshots().isEmpty)
        fixture.run()
        XCTAssertTrue(sampler.snapshots().isEmpty)
    }

    private final class Source: SessionLoadSource {
        var processCalls = 0
        var reads: [[SessionLoadTarget]] = []
        var births: [Int32: UInt64] = [:]
        var missing: Set<String> = []
        var duringProcesses: (() -> Void)?
        func processes(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> SessionLoadBatch {
            processCalls += 1
            let action = duringProcesses
            duringProcesses = nil
            action?()
            let processes = targets.flatMap { target -> [SessionLoadProcess] in
                let birth = births[target.backendPID] ?? 900_000_000
                var result = [SessionLoadProcess(pid: target.backendPID, parentPID: 1, userID: 501,
                    startedAtMicroseconds: birth, cpuNanoseconds: UInt64(processCalls), residentBytes: 100)]
                if let provider = target.providerPID {
                    result.append(SessionLoadProcess(pid: provider, parentPID: target.backendPID, userID: 501,
                        startedAtMicroseconds: birth + 1, cpuNanoseconds: 0, residentBytes: 20))
                }
                return result
            }
            return SessionLoadBatch(processes: processes, userID: 501, observedAt: moment.date,
                monotonicSeconds: moment.monotonicSeconds)
        }
        func hookTails(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> [SessionHookTail]? {
            reads.append(targets)
            return targets.compactMap { target in
                guard !missing.contains(target.paneID) else { return nil }
                return SessionHookTail(paneID: target.paneID, ownershipToken: target.ownershipToken,
                    providerSessionID: target.providerSessionID!, collectedAt: moment.date,
                    bytes: SessionHookFairnessTests.summary(at: Date(timeIntervalSince1970: 1000)))
            }
        }
    }

    private final class Fixture {
        let source = Source()
        let base = Date(timeIntervalSince1970: 1000)
        var targets: [SessionLoadTarget]
        var tick = 0.0
        var work: [() -> Void] = []
        init(count: Int) {
            targets = (0..<count).map {
                SessionLoadTarget(paneID: "pane-\($0)", backendPID: Int32(100 + $0), ownershipToken: "generation-\($0)",
                    provider: .claude, providerSessionID: UUID().uuidString, providerPID: Int32(2000 + $0))
            }
        }
        func sampler(source: SessionLoadSource? = nil) -> SessionLoadSampler {
            SessionLoadSampler(source: source ?? self.source, schedule: { self.work.append($0) }, clock: {
                SessionLoadMoment(date: self.base.addingTimeInterval(self.tick), monotonicSeconds: self.tick)
            })
        }
        func run() {
            let pending = work
            work = []
            for action in pending { action() }
        }
    }

    private static func summary(at date: Date) -> Data {
        let stamp = ISO8601DateFormatter().string(from: date)
        return Data("{\"type\":\"system\",\"subtype\":\"stop_hook_summary\",\"timestamp\":\"\(stamp)\",\"hookInfos\":[{\"durationMs\":25}]}\n".utf8)
    }
}
