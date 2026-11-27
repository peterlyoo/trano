import XCTest
@testable import TerminalCore

final class PessimisticTwinRuntimeGateTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-3, FR-TWIN-6, FR-TWIN-10
    func testOnlyExactRootDoneWithClearInputCanBecomeSnapshotOrMergeBoundary() throws {
        let fixture = try TwinFixture(); defer { fixture.remove() }
        let source = fixture.source
        var state = RuntimeState()
        var pane = TerminalSession(id: source.paneID, title: "Source", cwd: source.cwd, pid: source.backendPID)
        pane.activity.state = .done; pane.activity.source = "hook"
        var launch = AgentLaunch(paneID: source.paneID, provider: source.provider, providerSessionID: source.conversationID,
            cwd: source.cwd, accountID: nil, configurationRoot: source.configurationRoot, bootID: "fixture", processID: 125)
        launch.id = source.generation; launch.providerPID = source.providerPID
        var turn = FollowUpTurn(paneID: source.paneID, generation: source.generation)
        turn.promptID = "root-turn"; turn.completionID = "root-done"; turn.completedAt = Date(); turn.providerPID = source.providerPID; turn.providerIdentity = "provider-birth"
        state.sessions = [pane]; state.agentLaunches = [launch]; state.followUpTurns = [turn]
        func context(_ state: RuntimeState, revision: UInt64? = 9, backend: SupervisorProcessIdentity? = nil, pending: Bool = false) -> TwinRuntimeContext {
            TwinRuntimeGate.context(source: source, snapshot: state, backendBirth: backend ?? source.backendIdentity,
                providerBirth: source.providerIdentity, providerWitness: "provider-birth", inputRevision: revision,
                pendingDecisions: pending, enabled: true)
        }
        XCTAssertTrue(context(state).ready)
        XCTAssertEqual(context(state).completion?.inputRevision, 9)
        XCTAssertFalse(context(state, revision: nil).ready)
        XCTAssertFalse(context(state, pending: true).ready)
        var changed = state; changed.sessions[0].activity.source = "process"
        XCTAssertNil(context(changed).completion)
        changed = state; changed.agentLaunches[0].providerSessionID = UUID().uuidString
        XCTAssertNil(context(changed).source)
        changed = state; changed.followUpTurns[0].armed = true
        XCTAssertNil(context(changed).completion)
        changed = state; changed.followUpTurns[0].providerIdentity = "reused-pid"
        XCTAssertNil(context(changed).completion)
        changed = state; changed.followUpInputs = [FollowUpInput(paneID: source.paneID, text: "pending", generation: source.generation)]
        XCTAssertFalse(context(changed).ready)
        var monitor = AgentSupervision(generation: source.generation); monitor.unknownToolCount = 1
        changed = state; changed.supervision = [monitor]
        XCTAssertFalse(context(changed).ready)
    }

    func testHookInstructionsKeepTheScopedSocketAfterJSONEscaping() throws {
        let raw = JSONValue.object(["hookSpecificOutput": .object(["additionalContext": .string("Run EASYDECISION_SOCKET='/private/space path/api.sock' trano decision-adapter ask")])])
        let output = TwinAPIScope.hookOutput(raw, globalSocket: "/private/space path/api.sock", scopedSocket: "/private/space path/twin.sock")
        let roundtrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(output))
        XCTAssertEqual(roundtrip["hookSpecificOutput"]?["additionalContext"], .string("Run EASYDECISION_SOCKET='/private/space path/twin.sock' trano decision-adapter ask"))
    }

    func testTrustedHookStillRequiresFreshConversationAndOwnedWorktreeContext() {
        let original = UUID().uuidString.lowercased(), fresh = UUID().uuidString.lowercased()
        func payload(_ id: String, _ cwd: String, _ event: String = "SessionStart") -> JSONValue {
            .object(["session_id": .string(id), "cwd": .string(cwd), "hook_event_name": .string(event)])
        }
        XCTAssertTrue(TwinHookContext.matches(payload(fresh, "/own/tree"), sourceConversationID: original, worktree: "/own/tree"))
        for value in [payload(original.uppercased(), "/own/tree"), payload("invalid", "/own/tree"), payload(fresh, "/source"), payload(fresh, "/own/tree/../source"), payload(fresh, "/own/tree/subdir")] {
            XCTAssertFalse(TwinHookContext.matches(value, sourceConversationID: original, worktree: "/own/tree"))
        }
        XCTAssertTrue(TwinHookContext.matches(payload(fresh, "/own/tree/subdir", "PostToolUse"), sourceConversationID: original, worktree: "/own/tree"))
    }

    func testScopedAPIRejectsEveryGenericControlSurfaceBeforeRouting() throws {
        let fixture = try TwinFixture(); defer { fixture.remove() }
        let runtime = try TerminalRuntime(root: fixture.root)
        let scope = TwinAPIScope(runID: UUID().uuidString.lowercased())
        let service = APIService(runtime: runtime, twinScope: scope)
        for method in ["sessions.send", "sessions.terminate", "workspaces.launch", "decisions.resolve", "notifications.configure", "server.stop", "accounts.switch", "twins.enable", "twins.stop", "twins.respond", "twins.status"] {
            XCTAssertFalse(scope.permits(method), method)
            XCTAssertNotNil(service.route(APIRequest(method: method), originPID: getpid()).error, method)
        }
        XCTAssertTrue(scope.permits("twins.hook")); XCTAssertTrue(scope.permits("twins.report"))
        XCTAssertTrue(scope.permits("twins.commit")); XCTAssertTrue(scope.permits("twins.diff"))
        XCTAssertTrue(try runtime.state().sessions.isEmpty)
    }
}
