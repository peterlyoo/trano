import XCTest
@testable import TerminalCore

final class AgentTaskTests: XCTestCase {
    // Implements: FR-HOVER-3
    func testScannerAcceptsChildLifecycleWithoutChangingRootSemantics() throws {
        var scanner = ActivityScanner()
        let frames = "\u{1b}]7501;id=review/worker:state=working:app=codex:name=reviewer\u{7}"
            + "\u{1b}]7501;id=review/worker:state=blocked:app=codex\u{7}"
            + "\u{1b}]7501;id=review/worker:state=done:app=codex\u{1b}\\"
        var reports: [ActivityReport] = []
        for byte in frames.utf8 { reports += scanner.feed(Data([byte])) }
        XCTAssertEqual(reports.map(\.state), [.running, .blocked, .done])
        XCTAssertEqual(reports.map(\.agent), [.codex, .codex, .codex])
        XCTAssertTrue(reports.allSatisfy { !$0.clearsActive })
    }

    // Implements: FR-HOVER-3
    func testBothProvidersRegisterLifecycleHooks() {
        for provider in [AgentKind.claude, .codex] {
            let hooks = TerminalRuntime.activityHooks(provider)
            XCTAssertNotNil(hooks["SubagentStart"])
            XCTAssertNotNil(hooks["SubagentStop"])
        }
    }

    // Implements: FR-HOVER-1, FR-HOVER-3
    func testChildHooksUpdateOnlyTaskStateAndIgnorePrivatePayloadFields() throws {
        for provider in [AgentKind.claude, .codex] {
            try withRuntime { runtime, paneID in
                let launch = try runtime.beginAgentLaunch(paneID: paneID, provider: provider, cwd: runtime.root.path)
                let sessionID = UUID().uuidString
                try hook(runtime, paneID, launch, sessionID, "SessionStart")
                try hook(runtime, paneID, launch, sessionID, "PreToolUse", extra: ["tool_use_id": "root-tool"])
                let before = try runtime.state()
                try hook(runtime, paneID, launch, sessionID, "SubagentStart", extra: ["agent_id": "child", "agent_type": "reviewer", "prompt": "PRIVATE_SENTINEL", "agent_transcript_path": "/PRIVATE_SENTINEL", "last_assistant_message": "PRIVATE_SENTINEL"])
                XCTAssertEqual(try tasks(runtime).first?["activity"]?["state"]?.text, "running")
                XCTAssertEqual(try tasks(runtime).first?["name"]?.text, "reviewer")
                try hook(runtime, paneID, launch, sessionID, "PermissionRequest", extra: ["agent_id": "child"])
                XCTAssertEqual(try tasks(runtime).first?["activity"]?["state"]?.text, provider == .claude ? "blocked" : "running")
                try hook(runtime, paneID, launch, sessionID, "SubagentStop", extra: ["agent_id": "child"])
                let after = try runtime.state()
                XCTAssertEqual(try tasks(runtime).first?["activity"]?["state"]?.text, "done")
                XCTAssertEqual(after.sessions.first?.activity, before.sessions.first?.activity)
                XCTAssertEqual(after.supervision, before.supervision)
                XCTAssertEqual(after.events, before.events)
                XCTAssertEqual(after.agentLaunches.first?.providerSessionID, sessionID)
                XCTAssertEqual(after.agentLaunches.first?.lifecycle, .active)
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(after), as: UTF8.self).contains("PRIVATE_SENTINEL"))
            }
        }
    }

    // Implements: FR-HOVER-3, FR-HOVER-4
    func testChildHooksCannotBindRootAndRejectStaleGenerationOrUnrelatedProcess() throws {
        try withRuntime { runtime, paneID in
            let launch = try runtime.beginAgentLaunch(paneID: paneID, provider: .claude, cwd: runtime.root.path)
            let sessionID = UUID().uuidString
            try hook(runtime, paneID, launch, sessionID, "SubagentStart", extra: ["agent_id": "premature"])
            XCTAssertNil(try runtime.state().agentLaunches.first?.providerSessionID)
            XCTAssertTrue(try tasks(runtime).isEmpty)
            try hook(runtime, paneID, launch, sessionID, "SessionStart")
            try hook(runtime, paneID, launch, sessionID, "SubagentStart", extra: ["agent_id": "valid"])
            XCTAssertEqual(try tasks(runtime).count, 1)
            let before = try runtime.state().revision
            try hook(runtime, paneID, launch, UUID().uuidString, "SubagentStart", extra: ["agent_id": "foreign-session"])
            try hook(runtime, paneID, launch, sessionID, "SubagentStart", extra: ["agent_id": "stale"], generation: UUID().uuidString)
            try hook(runtime, paneID, launch, sessionID, "SubagentStart", extra: ["agent_id": "sdk-probe"], originPID: getpid())
            try hook(runtime, paneID, launch, sessionID, "SessionStart", extra: ["agent_id": "child-session"])
            XCTAssertEqual(try runtime.state().revision, before)
            XCTAssertEqual(try tasks(runtime).count, 1)
            try runtime.endAgentLaunch(paneID: paneID, generation: launch.id, normalExit: true)
            _ = try runtime.beginAgentLaunch(paneID: paneID, provider: .claude, cwd: runtime.root.path)
            XCTAssertTrue(try tasks(runtime).isEmpty)
        }
    }

    // Implements: FR-HOVER-4
    func testLegacyPaneDecodeAndChildMetadataRoundTrip() throws {
        let legacy = Data("{\"id\":\"pane\",\"title\":\"Terminal\",\"cwd\":\"/tmp\",\"pid\":1,\"host\":\"local\",\"agent\":\"shell\",\"activity\":{\"state\":\"unknown\",\"reason\":\"\",\"source\":\"unknown\",\"updatedAt\":0},\"createdAt\":0,\"alive\":true}".utf8)
        var pane = try JSONDecoder().decode(TerminalSession.self, from: legacy)
        XCTAssertNil(pane.agentTasks)
        pane.agentTasks = [AgentTask(id: "child", name: "reviewer", agent: .codex, generation: "launch")]
        XCTAssertEqual(try JSONDecoder().decode(TerminalSession.self, from: JSONEncoder().encode(pane)), pane)
    }

    // Implements: FR-HOVER-3
    func testOSCChildrenRemainPaneLocalAndCannotCompleteRootOrLeakMessage() throws {
        try withRuntime { runtime, paneID in
            let other = TerminalSession(id: UUID().uuidString.lowercased(), title: "Other", cwd: runtime.root.path, pid: 2)
            try runtime.update { $0.sessions.append(other) }
            let launch = try runtime.beginAgentLaunch(paneID: paneID, provider: .claude, cwd: runtime.root.path)
            try hook(runtime, paneID, launch, UUID().uuidString, "SessionStart")
            try runtime.report(paneID, state: .running, agent: .claude, source: "hook")
            let before = try runtime.state()
            try osc(runtime, paneID, "id=review/child:state=running:app=claude:name=reviewer")
            try osc(runtime, paneID, "id=review/child:state=blocked:app=claude:msg=" + Data("PRIVATE_OSC_SENTINEL".utf8).base64EncodedString())
            let task = try XCTUnwrap(runtime.state().sessions.first?.agentTasks?.first)
            XCTAssertEqual(task.id, "review/child")
            XCTAssertEqual(task.parentID, "review")
            XCTAssertEqual(task.name, "reviewer")
            XCTAssertEqual(task.activity.state, .blocked)
            XCTAssertEqual(task.activity.source, "osc7501")
            XCTAssertEqual(task.generation, launch.id)
            try osc(runtime, paneID, "id=review/child:state=done:app=claude")
            let after = try runtime.state()
            XCTAssertEqual(after.sessions.first?.activity, before.sessions.first?.activity)
            XCTAssertNil(after.sessions.last?.agentTasks)
            XCTAssertEqual(after.events, before.events)
            XCTAssertEqual(after.supervision, before.supervision)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(after), as: UTF8.self).contains("PRIVATE_OSC_SENTINEL"))
        }
    }

    // Implements: FR-HOVER-3, FR-HOVER-4
    func testOSCGenerationCannotReviveOldChildrenAndAbsentGenerationUsesCurrentLaunch() throws {
        try withRuntime { runtime, paneID in
            let first = try runtime.beginAgentLaunch(paneID: paneID, provider: .codex, cwd: runtime.root.path)
            try osc(runtime, paneID, "id=child:state=running:app=codex:generation=" + first.id)
            XCTAssertEqual(try runtime.state().sessions.first?.agentTasks?.count, 1)
            try runtime.endAgentLaunch(paneID: paneID, generation: first.id, normalExit: true)
            let second = try runtime.beginAgentLaunch(paneID: paneID, provider: .codex, cwd: runtime.root.path)
            XCTAssertNil(try runtime.state().sessions.first?.agentTasks)
            let before = try runtime.state().revision
            try osc(runtime, paneID, "id=child:state=done:app=codex:generation=" + first.id)
            XCTAssertEqual(try runtime.state().revision, before)
            try osc(runtime, paneID, "id=child:state=running:app=codex")
            XCTAssertEqual(try runtime.state().sessions.first?.agentTasks?.first?.generation, second.id)
        }
    }

    // Implements: FR-HOVER-3
    func testChildClearRemovesDescendantsWithoutTouchingOtherChildrenOrRoot() throws {
        try withRuntime { runtime, paneID in
            try runtime.report(paneID, state: .running, agent: .codex)
            for frame in ["id=review:state=running", "id=review/child:state=running", "id=grandchild:parent=review/child:state=running", "id=other:state=blocked"] {
                try osc(runtime, paneID, frame)
            }
            try osc(runtime, paneID, "id=review:state=clear")
            XCTAssertEqual(try runtime.state().sessions.first?.agentTasks?.map(\.id), ["other"])
            XCTAssertEqual(try runtime.state().sessions.first?.activity.state, .running)
            try osc(runtime, paneID, "state=clear")
            XCTAssertNil(try runtime.state().sessions.first?.agentTasks)
            XCTAssertEqual(try runtime.state().sessions.first?.activity.state, .unknown)
        }
    }

    // Implements: FR-HOVER-3
    func testChildBoundPreservesActiveTasksAndEvictsOldestInactiveTask() throws {
        try withRuntime { runtime, paneID in
            for number in 0..<64 { try osc(runtime, paneID, "id=worker-\(number):state=running") }
            try osc(runtime, paneID, "id=overflow:state=running")
            XCTAssertEqual(try runtime.state().sessions.first?.agentTasks?.count, 64)
            XCTAssertFalse(try runtime.state().sessions[0].agentTasks!.contains { $0.id == "overflow" })
            try osc(runtime, paneID, "id=worker-0:state=done")
            try osc(runtime, paneID, "id=worker-1:state=idle")
            try osc(runtime, paneID, "id=overflow:state=blocked")
            let tasks = try XCTUnwrap(runtime.state().sessions.first?.agentTasks)
            XCTAssertEqual(tasks.count, 64)
            XCTAssertFalse(tasks.contains { $0.id == "worker-0" })
            XCTAssertTrue(tasks.contains { $0.id == "worker-1" })
            XCTAssertEqual(tasks.last?.id, "overflow")
            XCTAssertEqual(tasks.last?.activity.state, .blocked)
        }
    }

    // Implements: FR-HOVER-3
    func testMalformedChildMetadataAndParentCycleAreRejected() throws {
        try withRuntime { runtime, paneID in
            try osc(runtime, paneID, "id=first:state=running")
            try osc(runtime, paneID, "id=second:parent=first:state=running")
            let before = try runtime.state().revision
            try osc(runtime, paneID, "id=first:parent=second:state=running")
            var scanner = ActivityScanner()
            for fields in ["id=:state=done", "id=a//b:state=done", "id=../a:state=done", "id=a:parent=a:state=done", "id=a:parent=../b:state=done", "id=a:name=" + String(repeating: "n", count: 129) + ":state=done"] {
                XCTAssertTrue(scanner.feed(Data(("\u{1b}]7501;" + fields + "\u{7}").utf8)).isEmpty)
            }
            XCTAssertEqual(try runtime.state().revision, before)
            XCTAssertNil(try runtime.state().sessions.first?.agentTasks?.first?.parentID)
        }
    }

    // Implements: FR-HOVER-4
    func testRemoteRootHoverRetainsProviderTimestampAndSource() throws {
        try withRuntime { runtime, paneID in
            let host = try runtime.addRemoteHost(name: "Fixture", address: "fixture.example")
            var remote = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/work", pid: 12)
            remote.agent = .codex
            remote.activity.state = .blocked
            remote.activity.source = "hook"
            remote.activity.reason = "Permission required"
            remote.activity.updatedAt = Date(timeIntervalSince1970: 1234)
            try runtime.update { $0.sessions[0].remote = RemoteReference(hostID: host.id, sessionID: remote.id) }
            try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
            XCTAssertEqual(try runtime.state().sessions[0].activity, remote.activity)
            XCTAssertEqual(try runtime.state().sessions[0].id, paneID)
            XCTAssertEqual(try runtime.state().events.count, 1)
            let revision = try runtime.state().revision
            try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
            XCTAssertEqual(try runtime.state().revision, revision)
            try runtime.update { $0.sessions[0].agent = .shell }
            try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
            XCTAssertEqual(try runtime.state().sessions[0].activity, remote.activity)
            XCTAssertEqual(try runtime.state().sessions[0].agent, .codex)
        }
    }

    // Implements: FR-HOVER-4
    func testRemoteTaskImportRefreshesChildrenWithoutRootEventsOrTimestampLoss() throws {
        try withRuntime { runtime, paneID in
            let host = try runtime.addRemoteHost(name: "Fixture", address: "fixture.example")
            var remote = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/work", pid: 12)
            var activity = Activity()
            activity.state = .running; activity.source = "hook"; activity.updatedAt = Date(timeIntervalSince1970: 1234)
            remote.agentTasks = [AgentTask(id: "remote-child", name: "reviewer", agent: .codex, activity: activity, generation: UUID().uuidString)]
            try runtime.update {
                $0.sessions[0].remote = RemoteReference(hostID: host.id, sessionID: remote.id)
                $0.sessions[0].cwd = remote.cwd
            }
            let before = try runtime.state()
            try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
            XCTAssertEqual(try runtime.state().sessions.first?.agentTasks, remote.agentTasks)
            XCTAssertEqual(try runtime.state().events, before.events)
            let revision = try runtime.state().revision
            try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
            XCTAssertEqual(try runtime.state().revision, revision)
            remote.agentTasks = nil
            try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
            XCTAssertNil(try runtime.state().sessions.first?.agentTasks)
            XCTAssertEqual(try runtime.state().sessions.first?.id, paneID)
        }
    }

    private func osc(_ runtime: TerminalRuntime, _ paneID: String, _ fields: String) throws {
        var scanner = ActivityScanner()
        let report = try XCTUnwrap(scanner.feed(Data(("\u{1b}]7501;" + fields + "\u{7}").utf8)).first)
        try runtime.report(paneID, report: report)
    }

    private func withRuntime(_ body: (TerminalRuntime, String) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/tmp/trano-task-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Task fixture", cwd: root.path, pid: 1)
        try runtime.update { $0.sessions.append(pane) }
        try body(runtime, pane.id)
    }

    private func hook(_ runtime: TerminalRuntime, _ paneID: String, _ launch: AgentLaunch, _ sessionID: String,
                      _ event: String, extra: [String: String] = [:], generation: String? = nil, originPID: Int32? = nil) throws {
        var payload = extra
        payload["session_id"] = sessionID
        payload["cwd"] = runtime.root.path
        payload["hook_event_name"] = event
        try runtime.recordAgentHook(paneID: paneID, generation: generation ?? launch.id, provider: launch.provider,
                                    data: JSONEncoder().encode(payload), originPID: originPID)
    }

    private func tasks(_ runtime: TerminalRuntime) throws -> [JSONValue] {
        let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(runtime.state().sessions[0]))
        return payload["agentTasks"]?.array ?? []
    }
}
