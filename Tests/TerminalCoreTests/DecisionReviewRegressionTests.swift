import XCTest
import Darwin
@testable import TerminalCore

final class DecisionReviewRegressionTests: XCTestCase {
    private func fixture() throws -> (TerminalRuntime, AgentLaunch) {
        let root = URL(fileURLWithPath: "/tmp/tdr-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let paneID = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: paneID, title: "Fixture", cwd: root.path, pid: 0)) }
        var launch = try runtime.beginAgentLaunch(paneID: paneID, provider: .codex, cwd: root.path)
        launch.providerSessionID = UUID().uuidString.lowercased()
        launch.providerPID = getpid()
        try runtime.update { $0.agentLaunches = [launch] }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (runtime, launch)
    }

    private func question(_ launch: AgentLaunch) -> JSONValue {
        .object(["schema_version": .string("1.0"), "request_id": .string(UUID().uuidString.lowercased()),
                 "thread_id": .string(UUID().uuidString.lowercased()),
                 "source": .object(["agent": .string(launch.provider.rawValue), "session_id": .string(launch.providerSessionID!), "workspace": .string(launch.cwd)]),
                 "question": .string("Choose a storage option."),
                 "options": .array([.object(["id": .string("disk"), "label": .string("Disk"), "description": .string("Keeps data.")]),
                                    .object(["id": .string("memory"), "label": .string("Memory"), "description": .string("Clears data.")])])])
    }

    private func submit(_ question: JSONValue, launch: AgentLaunch? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("submit"), "question": question]
        if let launch { fields["trano_binding"] = .object(["pane_id": .string(launch.paneID), "generation": .string(launch.id)]) }
        return .object(fields)
    }

    private func sleeper() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        addTeardownBlock { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        return child
    }

    // Implements: FR-DECISION-1, FR-DECISION-2
    func testNativeEnvelopeBindsCurrentProducerAndRejectsDelayedGeneration() throws {
        let (runtime, launch) = try fixture()
        let first = question(launch)
        XCTAssertEqual(try runtime.decisionAdapter(submit(first, launch: launch))["status"], .string("pending"))
        var replacement = launch
        replacement.id = UUID().uuidString.lowercased()
        try runtime.update { $0.agentLaunches = [replacement] }
        XCTAssertEqual(try runtime.decisionAdapter(submit(question(launch), launch: launch))["error"], .string("SESSION_NOT_BOUND"))
        XCTAssertEqual(try runtime.decisionAdapter(submit(question(replacement), launch: replacement))["status"], .string("pending"))
        let wrongPane: JSONValue = .object(["type": .string("submit"), "question": question(replacement),
                                            "trano_binding": .object(["pane_id": .string(UUID().uuidString.lowercased()), "generation": .string(replacement.id)])])
        XCTAssertEqual(try runtime.decisionAdapter(wrongPane)["error"], .string("SESSION_NOT_BOUND"))
    }

    // Implements: FR-DECISION-1, FR-DECISION-2
    func testNativeAdapterCapturesInheritedPaneAndGeneration() throws {
        let (_, launch) = try fixture()
        let keys = ["TRANO_SESSION", "TRANO_LAUNCH_ID"]
        let previous = keys.map { getenv($0).map { String(cString: $0) } }
        defer { for (key, value) in zip(keys, previous) { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        setenv(keys[0], launch.paneID, 1)
        setenv(keys[1], launch.id, 1)
        var captured: JSONValue?
        let code = DecisionAdapterCommand.run(arguments: ["submit"], socketPath: "/tmp/unused.sock",
            input: { try JSONEncoder().encode(self.question(launch)) }, output: { _ in }, transport: { request in
                captured = request
                return .object(["ok": .bool(true), "status": .string("pending")])
            })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(captured?["trano_binding"]?["pane_id"], .string(launch.paneID))
        XCTAssertEqual(captured?["trano_binding"]?["generation"], .string(launch.id))
    }

    // Implements: FR-DECISION-1, FR-DECISION-2
    func testRawSocketRequiresCurrentProviderPeerForLegacyAndNativeIntake() throws {
        let (runtime, launch) = try fixture()
        let service = APIService(runtime: runtime)
        try service.start()
        defer { service.stop() }
        let client = DecisionAdapterClient(path: service.path)
        XCTAssertEqual(try client.call(submit(question(launch)))["status"], .string("pending"))
        let unrelated = try sleeper()
        try runtime.recordAgentProcess(paneID: launch.paneID, generation: launch.id, pid: unrelated.processIdentifier)
        XCTAssertEqual(try client.call(submit(question(launch)))["error"], .string("SESSION_NOT_BOUND"))
        XCTAssertEqual(try client.call(submit(question(launch), launch: launch))["error"], .string("SESSION_NOT_BOUND"))
    }

    // Implements: FR-DECISION-2, FR-DECISION-3
    func testAbnormalExitAbandonsPendingAndUnreadAnswersButPreservesDeliveredAnswers() throws {
        let (runtime, launch) = try fixture()
        let pending = question(launch), unread = question(launch), delivered = question(launch)
        for input in [pending, unread, delivered] { _ = try runtime.decisionAdapter(submit(input)) }
        let pendingID = pending["request_id"]!.text!, unreadID = unread["request_id"]!.text!, deliveredID = delivered["request_id"]!.text!
        _ = try runtime.resolveDecision(unreadID, generation: launch.id, action: "choose", optionID: "disk")
        _ = try runtime.resolveDecision(deliveredID, generation: launch.id, action: "choose", optionID: "disk")
        _ = try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(deliveredID)]))
        try runtime.endAgentLaunch(paneID: launch.paneID, generation: launch.id, normalExit: false)
        XCTAssertEqual(try runtime.state().agentLaunches.first?.lifecycle, .active)
        let statuses = Dictionary(uniqueKeysWithValues: try runtime.decisionInbox().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses[pendingID], "abandoned")
        XCTAssertEqual(statuses[unreadID], "abandoned")
        XCTAssertEqual(statuses[deliveredID], "resolved")
        XCTAssertThrowsError(try runtime.resolveDecision(pendingID, generation: launch.id, action: "choose", optionID: "disk"))
        XCTAssertEqual(try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(unreadID)]))["status"], .string("abandoned"))
    }

    // Implements: FR-DECISION-2
    func testDeadSupervisorCannotKeepPendingQuestionsOrAcceptNewOnes() throws {
        let (runtime, launch) = try fixture()
        _ = try runtime.decisionAdapter(submit(question(launch)))
        try runtime.update { $0.agentLaunches[0].processID = Int32.max }
        XCTAssertEqual(try runtime.decisionInbox().first?.status, "abandoned")
        XCTAssertEqual(try runtime.decisionAdapter(submit(question(launch)))["error"], .string("SESSION_NOT_BOUND"))
    }

    // Implements: FR-DECISION-1, FR-DECISION-2, FR-QUEUE-2, FR-QUEUE-3
    func testStopGateRetainsArmedFollowUpUntilTheAnswerIsRead() throws {
        let (runtime, launch) = try fixture()
        let origin = try sleeper()
        func hook(_ event: String) throws -> Data {
            try JSONEncoder().encode(["hook_event_name": event, "session_id": launch.providerSessionID!, "cwd": launch.cwd])
        }
        let prompt = try hook("UserPromptSubmit"), stop = try hook("Stop")
        try runtime.recordAgentHook(paneID: launch.paneID, generation: launch.id, provider: .codex, data: prompt, originPID: origin.processIdentifier)
        _ = try runtime.addFollowUp(paneID: launch.paneID, text: "Run this on the next completed turn.")
        let input = question(launch), id = input["request_id"]!.text!
        _ = try runtime.decisionAdapter(submit(input))
        try runtime.recordAgentHook(paneID: launch.paneID, generation: launch.id, provider: .codex, data: stop, originPID: origin.processIdentifier)
        var state = try runtime.state()
        XCTAssertNil(state.followUpTurns.first?.completionID)
        XCTAssertEqual(state.followUpTurns.first?.armed, true)
        XCTAssertNotEqual(state.sessions.first?.activity.state, .done)
        let blocked = try runtime.decisionHookOutput(paneID: launch.paneID, generation: launch.id, provider: .codex, data: stop, originPID: origin.processIdentifier)
        XCTAssertEqual(blocked?["decision"], .string("block"))
        XCTAssertTrue(blocked?["reason"]?.text?.contains(id) == true)
        XCTAssertFalse(blocked?["reason"]?.text?.contains("Choose a storage option.") == true)
        _ = try runtime.resolveDecision(id, generation: launch.id, action: "choose", optionID: "disk")
        XCTAssertEqual(try runtime.decisionHookOutput(paneID: launch.paneID, generation: launch.id, provider: .codex, data: stop, originPID: origin.processIdentifier)?["decision"], .string("block"))
        _ = try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(id)]))
        try runtime.recordAgentHook(paneID: launch.paneID, generation: launch.id, provider: .codex, data: stop, originPID: origin.processIdentifier)
        state = try runtime.state()
        XCTAssertNotNil(state.followUpTurns.first?.completionID)
        XCTAssertEqual(state.followUpTurns.first?.armed, false)
        XCTAssertEqual(state.sessions.first?.activity.state, .done)
        XCTAssertEqual(try runtime.decisionHookOutput(paneID: launch.paneID, generation: launch.id, provider: .codex, data: stop, originPID: origin.processIdentifier), .object([:]))
        let context = try XCTUnwrap(runtime.decisionHookOutput(paneID: launch.paneID, generation: launch.id, provider: .codex, data: prompt, originPID: origin.processIdentifier)?["hookSpecificOutput"]?["additionalContext"]?.text)
        XCTAssertTrue(context.contains("TRANO_SESSION=" + ShellQuote.quote(launch.paneID)))
        XCTAssertTrue(context.contains("TRANO_LAUNCH_ID=" + ShellQuote.quote(launch.id)))
    }
}
