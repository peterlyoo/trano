import Foundation
import XCTest
@testable import TerminalCore

final class TerminalShellHandoffTests: XCTestCase {
    // Implements: FR-INPUT-1
    func testReadySnapshotUsesFreshShellBindingWithoutChangingRuntimeState() throws {
        let f = try Fixture(); defer { f.close() }
        let before = try encodedState(f.runtime)
        let status = try f.runtime.terminalShellHandoff(f.request, readShell: { _ in "100:birth:tty:100" }, hasExited: { _ in false })
        guard case .ready(let value) = status else { return XCTFail("Expected the same foreground shell") }
        XCTAssertEqual(value.binding, TerminalInputBinding(paneID: f.id, backendPID: 100, generation: "terminal:100"))
        XCTAssertEqual(try encodedState(f.runtime), before)
    }
    func testMissingForegroundWitnessKeepsInputWaiting() throws {
        let f = try Fixture(); defer { f.close() }
        guard case .waiting = try f.runtime.terminalShellHandoff(f.request, readShell: { _ in nil }, hasExited: { _ in true }) else { return XCTFail("Missing proof must wait") }
    }
    func testChangedBackendRejectsBeforeAnyProbe() throws {
        let f = try Fixture(); defer { f.close() }
        try f.runtime.update { $0.sessions[0].pid = 101 }
        guard case .changed = try f.runtime.terminalShellHandoff(f.request, readShell: { _ in XCTFail("No probe for a replaced backend"); return "shell" }, hasExited: { _ in true }) else { return XCTFail("Expected rejection") }
    }
    func testNewExitedGenerationDuringProbeCannotBecomeTheOriginalShell() throws {
        let f = try Fixture(); defer { f.close() }
        let status = try f.runtime.terminalShellHandoff(f.request, readShell: { _ in
            var launch = f.launch(); launch.lifecycle = .exited
            try f.runtime.update { $0.agentLaunches.append(launch) }
            return "same-shell"
        }, hasExited: { _ in true })
        guard case .changed = status else { return XCTFail("A newer generation remains a changed destination even after exit") }
    }
    func testStaleActiveLaunchRequiresBothCapturedProcessDeathsWithoutInventingAnExit() throws {
        let f = try Fixture(); defer { f.close() }
        let launch = f.launch(); try f.runtime.update { $0.agentLaunches = [launch] }
        var request = f.makeRequest(launch: launch)
        request.providerPID = launch.providerPID; request.supervisorPID = launch.processID
        guard case .waiting = try f.runtime.terminalShellHandoff(request, readShell: { _ in "shell" }, hasExited: { $0.pid == 200 }) else { return XCTFail("A live supervisor must keep the gate closed") }
        let before = try encodedState(f.runtime)
        guard case .ready(let snapshot) = try f.runtime.terminalShellHandoff(request, readShell: { _ in "shell" }, hasExited: { _ in true }) else { return XCTFail("Proved process deaths may release a stale active record") }
        XCTAssertEqual(snapshot.binding.generation, launch.id)
        XCTAssertEqual(try encodedState(f.runtime), before, "Readiness must not synthesize provider cleanup")
    }
    func testAReplacedProviderPIDInTheSameGenerationDoesNotReleaseInput() throws {
        let f = try Fixture(); defer { f.close() }
        let launch = f.launch(); try f.runtime.update { $0.agentLaunches = [launch] }
        var request = f.makeRequest(launch: launch); request.providerPID = 200; request.supervisorPID = 150
        let status = try f.runtime.terminalShellHandoff(request, readShell: { _ in
            try f.runtime.update { $0.agentLaunches[0].providerPID = 201 }; return "shell"
        }, hasExited: { _ in true })
        guard case .waiting = status else { return XCTFail("A different provider process is not the captured exit") }
    }
    func testRemoteBackendWitnessReplacementRejectsBeforeProbe() throws {
        let f = try Fixture(); defer { f.close() }
        let remote = RemoteReference(hostID: "host", sessionID: UUID().uuidString)
        try f.runtime.update { $0.sessions[0].remote = remote; $0.sessions[0].inputBackendIdentity = "new-birth" }
        var request = TerminalShellHandoffRequest(paneID: f.id, backendPID: 100, remote: remote, backend: nil, launchIDs: [], activeLaunchID: nil, processes: [])
        request.remoteBackendIdentity = "old-birth"
        guard case .changed = try f.runtime.terminalShellHandoff(request, readShell: { _ in XCTFail("Remote incarnation changed"); return "new-birth" }, hasExited: { _ in true }) else { return XCTFail("Expected rejection") }
    }
    func testLegacySessionJSONWithoutOptionalWitnessStillDecodes() throws {
        let f = try Fixture(); defer { f.close() }
        let encoded = try JSONEncoder().encode(try f.runtime.state().sessions[0])
        XCTAssertNil(try JSONDecoder().decode(TerminalSession.self, from: encoded).inputBackendIdentity)
    }
    private func encodedState(_ runtime: TerminalRuntime) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(runtime.state())
    }
    private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let id = UUID().uuidString.lowercased()
        var request: TerminalShellHandoffRequest { TerminalShellHandoffRequest(paneID: id, backendPID: 100, remote: nil, backend: nil, launchIDs: [], activeLaunchID: nil, processes: []) }
        init() throws {
            root = URL(fileURLWithPath: "/tmp/trano-sh-" + UUID().uuidString.prefix(8)); runtime = try TerminalRuntime(root: root)
            try runtime.update { $0.sessions = [TerminalSession(id: id, title: "Unit", cwd: root.path, pid: 100)] }
        }
        func launch() -> AgentLaunch { AgentLaunch(paneID: id, provider: .codex, cwd: root.path, accountID: nil, configurationRoot: root.path, bootID: "unit", processID: 150, providerPID: 200) }
        func makeRequest(launch: AgentLaunch) -> TerminalShellHandoffRequest {
            TerminalShellHandoffRequest(paneID: id, backendPID: 100, remote: nil, backend: nil, launchIDs: [launch.id], activeLaunchID: launch.id,
                processes: [150, 200].map { SupervisorProcessIdentity(pid: $0, ownerUID: 1, startedAtSeconds: 1, startedAtMicroseconds: 1) })
        }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
}
