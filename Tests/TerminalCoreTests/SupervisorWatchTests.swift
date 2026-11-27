import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorWatchTests: XCTestCase {
    // Implements: FR-SUP-3, FR-SUP-5
    func testARelevantChangeReturnsImmediatelyWithoutWaiting() throws {
        let source = WakeSource()
        let peer = TerminalSession(id: UUID().uuidString, title: "Peer", cwd: "/tmp", pid: 1234)
        let value = SupervisorProjection.state(binding: nil, observation: SupervisorObservation(sessions: [peer]))
        let watcher = SupervisorWatcher(source: source, observe: { value }, now: { 0 })
        let result = try watcher.wait(after: SupervisorWatchCursor(), timeout: 2700)
        XCTAssertEqual(result.reason, .changed)
        XCTAssertEqual(result.state.cursor, value.cursor)
        XCTAssertEqual(source.calls, 0)
    }

    // Implements: FR-SUP-3, FR-SUP-5
    func testSelfOnlyAndTitleOnlyEventsDoNotWakeTheSupervisor() throws {
        let source = WakeSource()
        let own = TerminalSession(id: UUID().uuidString, title: "Supervisor", cwd: "/tmp", pid: 1234)
        let peer = TerminalSession(id: UUID().uuidString, title: "Peer", cwd: "/tmp", pid: 1235)
        let binding = SupervisorBinding(paneID: own.id, backendPID: own.pid, configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"))
        var observation = SupervisorObservation(sessions: [own, peer])
        let before = SupervisorProjection.state(binding: binding, observation: observation).cursor
        var clock: TimeInterval = 0
        source.onWait = { _ in
            clock += 1
            if source.calls == 1 {
                observation.sessions[0].activity.state = .running
                observation.sessions[1].terminalTitle = "Title only"
            } else { observation.sessions[1].activity.state = .done }
            return true
        }
        let watcher = SupervisorWatcher(source: source,
            observe: { SupervisorProjection.state(binding: binding, observation: observation) }, now: { clock })
        let result = try watcher.wait(after: before, timeout: 2700)
        XCTAssertEqual(result.reason, .changed)
        XCTAssertEqual(source.calls, 2)
    }

    // Implements: FR-SUP-3, FR-SUP-5
    func testTimeoutReturnsAHeartbeatAndInvalidTimeoutNeverTouchesTheSource() throws {
        let source = WakeSource()
        let state = SupervisorProjection.state(binding: nil, observation: SupervisorObservation())
        let watcher = SupervisorWatcher(source: source, observe: { state }, now: { 0 })
        let result = try watcher.wait(after: state.cursor, timeout: 2700)
        XCTAssertEqual(result.reason, .heartbeat)
        XCTAssertEqual(source.calls, 1)
        for timeout in [0, -1, 3601, .infinity, .nan] {
            XCTAssertThrowsError(try watcher.wait(after: state.cursor, timeout: timeout))
        }
        XCTAssertEqual(source.calls, 1)
    }

    private final class WakeSource: SupervisorWakeSource {
        var calls = 0
        var onWait: ((TimeInterval) -> Bool)?
        func wait(timeout: TimeInterval) -> Bool { calls += 1; return onWait?(timeout) ?? false }
    }
}
