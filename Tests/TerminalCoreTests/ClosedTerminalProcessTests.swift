import Darwin
import XCTest
@testable import TerminalCore

// Implements: FR-CLOSE-2, FR-CLOSE-4
final class ClosedTerminalProcessTests: XCTestCase {
    func testVerifiedCaptureRejectsFailedOrFullCensusBeforeAnySignal() {
        let f = Fake(); f.add(10, parent: 1)
        let pane = TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: "/tmp", pid: 10)
        f.censusFails = true
        XCTAssertThrowsError(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: nil, environment: f.environment))
        f.censusFails = false; f.censusOverride = Array(repeating: 10, count: 65_536)
        XCTAssertThrowsError(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: nil, environment: f.environment))
        XCTAssertTrue(f.signals.isEmpty)
    }

    func testVerifiedCaptureDistinguishesUninspectableRootFromExitedRoot() throws {
        let f = Fake(); f.add(10, parent: 1)
        let pane = TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: "/tmp", pid: 10)
        f.probeFails = true
        XCTAssertThrowsError(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: nil, environment: f.environment))
        f.probeFails = false; f.records.removeValue(forKey: 10)
        XCTAssertTrue(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: nil, environment: f.environment).isEmpty)
        XCTAssertTrue(f.signals.isEmpty)
    }

    func testVerifiedCaptureRetriesATransientProbeFailureAndStillRejectsAPersistentOne() throws {
        let f = Fake(); f.add(10, parent: 1); f.add(11, parent: 10); f.add(99, parent: 1)
        let pane = TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: "/tmp", pid: 10)
        f.inspectFailures = [99: 1]
        XCTAssertEqual(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: nil, environment: f.environment).map(\.pid), [11, 10])
        f.inspectFailures = [99: 3]
        XCTAssertThrowsError(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: nil, environment: f.environment))
        XCTAssertTrue(f.signals.isEmpty)
    }

    func testVerifiedCaptureRejectsExplicitProcessesBeyondTheCensusBound() {
        let f = Fake()
        let census = (2...65_536).map { Int32($0) }
        for pid in census { f.add(pid, parent: 1) }
        f.add(65_537, parent: 10)
        f.censusOverride = census
        let pane = TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: "/tmp", pid: 10)
        let launch = AgentLaunch(paneID: pane.id, provider: .claude, cwd: "/tmp", accountID: nil,
            configurationRoot: "/tmp", bootID: "fixture", processID: 65_537)
        XCTAssertThrowsError(try ClosedTerminalProcesses.captureVerified(pane: pane, launch: launch, environment: f.environment))
        XCTAssertTrue(f.signals.isEmpty)
    }

    func testCaptureIncludesBackgroundDescendantsButRejectsUnrelatedProviderPID() {
        let f = Fake()
        f.add(10, parent: 1); f.add(11, parent: 10); f.add(12, parent: 11)
        f.add(13, parent: 10, owner: 999); f.add(99, parent: 1)
        let pane = TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: "/tmp", pid: 10)
        let launch = AgentLaunch(paneID: pane.id, provider: .claude, cwd: "/tmp", accountID: nil,
            configurationRoot: "/tmp", bootID: "fixture", processID: 11, providerPID: 99)
        let captured = ClosedTerminalProcesses.capture(pane: pane, launch: launch, environment: f.environment)
        XCTAssertEqual(captured.map(\.pid), [12, 11, 10])
        XCTAssertTrue(f.signals.isEmpty)
    }

    func testCaptureRejectsMissingRootAndExcludesClosingHelperSubtree() {
        let f = Fake(selfPID: 11)
        f.add(10, parent: 1); f.add(11, parent: 10); f.add(12, parent: 11); f.add(13, parent: 10)
        let pane = TerminalSession(id: UUID().uuidString, title: "Fixture", cwd: "/tmp", pid: 10)
        XCTAssertEqual(ClosedTerminalProcesses.capture(pane: pane, launch: nil, environment: f.environment).map(\.pid), [13, 10])
        f.records.removeValue(forKey: 10)
        XCTAssertTrue(ClosedTerminalProcesses.capture(pane: pane, launch: nil, environment: f.environment).isEmpty)
    }

    func testStopExitsAfterGracefulSignalsWithoutEscalation() throws {
        let f = Fake(); f.add(10, parent: 1); f.add(11, parent: 10)
        f.exitOnTerm = true
        try ClosedTerminalProcesses.stop([f.witness(11), f.witness(10)], environment: f.environment)
        XCTAssertEqual(f.signals.map(\.0), [11, 10])
        XCTAssertEqual(f.signals.map(\.1), [SIGTERM, SIGTERM])
        XCTAssertEqual(f.time, 0)
    }

    func testStopEscalatesWithinOneSecondAndVerifiesExit() throws {
        let f = Fake(); f.add(10, parent: 1)
        try ClosedTerminalProcesses.stop([f.witness(10)], environment: f.environment)
        XCTAssertEqual(f.signals.map(\.1), [SIGTERM, SIGKILL])
        XCTAssertGreaterThan(f.time, 0)
        XCTAssertLessThanOrEqual(f.time, 1)
        XCTAssertNil(f.records[10])
    }

    func testReusedPIDsAndHelperSelfAreNeverSignalled() throws {
        let f = Fake(selfPID: 11); f.add(10, parent: 1); f.add(11, parent: 1)
        let old = f.witness(10)
        f.add(10, parent: 1, birth: 9999)
        try ClosedTerminalProcesses.stop([old, f.witness(11)], environment: f.environment)
        XCTAssertTrue(f.signals.isEmpty)
    }

    func testPIDReuseBetweenTermAndEscalationPreventsKill() throws {
        let f = Fake(); f.add(10, parent: 1)
        f.onWait = { f.add(10, parent: 1, birth: 9999) }
        try ClosedTerminalProcesses.stop([f.witness(10)], environment: f.environment)
        XCTAssertEqual(f.signals.map(\.1), [SIGTERM])
    }

    func testUnknownIdentityAndSignalFailureStopWithoutUnsafeEscalation() {
        let f = Fake(); f.add(10, parent: 1)
        let witness = f.witness(10)
        f.unknown.insert(10)
        XCTAssertThrowsError(try ClosedTerminalProcesses.stop([witness], environment: f.environment))
        XCTAssertTrue(f.signals.isEmpty)
        f.unknown.remove(10); f.signalFails = true
        XCTAssertThrowsError(try ClosedTerminalProcesses.stop([witness], environment: f.environment))
        XCTAssertEqual(f.signals.map(\.1), [SIGTERM])
    }

    func testUnexitedProcessProducesBoundedFailure() {
        let f = Fake(); f.add(10, parent: 1); f.exitOnKill = false
        XCTAssertThrowsError(try ClosedTerminalProcesses.stop([f.witness(10)], environment: f.environment))
        XCTAssertEqual(f.signals.map(\.1), [SIGTERM, SIGKILL])
        XCTAssertLessThanOrEqual(f.time, 1)
    }

    private final class Fake {
        var records: [Int32: ClosedTerminalProcesses.Process] = [:]
        var signals: [(Int32, Int32)] = []
        var unknown: Set<Int32> = []
        var exitOnTerm = false
        var exitOnKill = true
        var signalFails = false
        var time: TimeInterval = 0
        var onWait: (() -> Void)?
        var censusFails = false
        var censusOverride: [Int32]?
        var probeFails = false
        var inspectFailures: [Int32: Int] = [:]
        let selfPID: Int32
        init(selfPID: Int32 = 500) { self.selfPID = selfPID }
        func add(_ pid: Int32, parent: Int32, owner: UInt32 = 501, birth: UInt64? = nil) {
            records[pid] = .init(identity: .init(pid: pid, ownerUID: owner,
                startedAtSeconds: birth ?? UInt64(1000 + pid), startedAtMicroseconds: 0), parentPID: parent)
        }
        func witness(_ pid: Int32) -> SupervisorProcessIdentity { records[pid]!.identity }
        var environment: ClosedTerminalProcesses.Environment {
            .init(ownerUID: 501, selfPID: selfPID, pids: {
                    if self.censusFails { throw TerminalError.runtime("fixture census unavailable") }
                    return self.censusOverride ?? Array(self.records.keys)
                }, process: {
                    if self.probeFails { throw TerminalError.runtime("fixture process unavailable") }
                    if let left = self.inspectFailures[$0], left > 0 {
                        self.inspectFailures[$0] = left - 1
                        throw TerminalError.runtime(ClosedTerminalProcesses.inspectFailure)
                    }
                    return self.unknown.contains($0) ? nil : self.records[$0]
                },
                hasExited: { !self.unknown.contains($0.pid) && self.records[$0.pid]?.identity != $0 },
                signal: { pid, signal in
                    self.signals.append((pid, signal))
                    if self.signalFails { return -1 }
                    if signal == SIGTERM && self.exitOnTerm || signal == SIGKILL && self.exitOnKill {
                        self.records.removeValue(forKey: pid)
                    }
                    return 0
                }, now: { self.time }, wait: { self.time += $0; self.onWait?() })
        }
    }
}
