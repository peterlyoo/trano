import XCTest
@testable import TerminalCore

final class DecisionInboxTests: XCTestCase {
    // Implements: FR-DECISION-1
    func testPublicInboxEncodingIncludesItsImmutableRequestID() throws {
        let (runtime, launch) = try fixture()
        let request = question(launch)
        _ = try ask(runtime, request)
        let entry = try XCTUnwrap(try runtime.decisionInbox().first)
        var value = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(value["id"], request["request_id"])
        value["id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try JSONDecoder().decode(DecisionInboxEntry.self, from: JSONEncoder().encode(value)))
        value.removeValue(forKey: "id")
        XCTAssertEqual(try JSONDecoder().decode(DecisionInboxEntry.self, from: JSONEncoder().encode(value)).id, entry.id)
    }

    // Implements: FR-DECISION-2
    func testWorkspaceWithKoreanAndTrailingSpaceKeepsItsExactBinding() throws {
        let (runtime, original) = try fixture()
        let folder = runtime.root.appendingPathComponent("한글 프로젝트 ")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var launch = original
        launch.cwd = folder.path
        try runtime.update { $0.agentLaunches = [launch] }
        let response = try ask(runtime, question(launch))
        XCTAssertEqual(response["ok"], .bool(true))
        XCTAssertEqual(try runtime.decisionInbox().first?.question.source.workspace, folder.path)
    }

    private func fixture() throws -> (TerminalRuntime, AgentLaunch) {
        let root = URL(fileURLWithPath: "/tmp/td-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let paneID = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: paneID, title: "Fixture", cwd: root.path, pid: 0)) }
        var launch = try runtime.beginAgentLaunch(paneID: paneID, provider: .codex, cwd: root.path)
        launch.providerSessionID = UUID().uuidString.lowercased()
        try runtime.update { $0.agentLaunches = [launch] }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (runtime, launch)
    }

    private func question(_ launch: AgentLaunch, requestID: String = UUID().uuidString.lowercased()) -> [String: JSONValue] {
        ["schema_version": .string("1.0"), "request_id": .string(requestID), "thread_id": .string(UUID().uuidString.lowercased()),
         "source": .object(["agent": .string("codex"), "session_id": .string(launch.providerSessionID!), "workspace": .string(launch.cwd)]),
         "question": .object(["ko": .string("어떤 저장소를 사용할까요?")]),
         "options": .array([.object(["id": .string("disk"), "label": .string("Disk (Recommended)"), "description": .string("Keep data after restart.")]),
                            .object(["id": .string("memory"), "label": .string("Memory"), "description": .string("Clear data after exit.")])])]
    }

    private func ask(_ runtime: TerminalRuntime, _ value: [String: JSONValue]) throws -> JSONValue {
        try runtime.decisionAdapter(.object(["type": .string("submit"), "question": .object(value)]))
    }

    // Implements: FR-DECISION-1, FR-DECISION-2
    func testDurableAskExactBindingAndIdempotency() throws {
        let (runtime, launch) = try fixture()
        let input = question(launch), id = input["request_id"]!.text!
        XCTAssertEqual(try ask(runtime, input)["status"], .string("pending"))
        XCTAssertEqual(try ask(runtime, input)["status"], .string("pending"))
        let reopened = try TerminalRuntime(root: runtime.root)
        let entries = try reopened.decisionInbox()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].paneID, launch.paneID)
        XCTAssertEqual(entries[0].generation, launch.id)
        XCTAssertEqual(entries[0].question.question.en, "어떤 저장소를 사용할까요?")
        XCTAssertEqual(entries[0].question.source.workspace, launch.cwd)
        XCTAssertEqual(entries[0].id, id)
        var collision = input
        collision["question"] = .string("Different question")
        XCTAssertEqual(try ask(runtime, collision)["error"], .string("REQUEST_ID_CONFLICT"))
        var wrong = input
        wrong["request_id"] = .string(UUID().uuidString.lowercased())
        wrong["source"] = .object(["agent": .string("codex"), "session_id": .string(launch.providerSessionID!), "workspace": .string(launch.cwd + "/other")])
        XCTAssertEqual(try ask(runtime, wrong)["error"], .string("SESSION_NOT_BOUND"))
        let attrs = try FileManager.default.attributesOfItem(atPath: runtime.root.appendingPathComponent("decision-inbox.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Implements: FR-DECISION-2, FR-DECISION-3
    func testChoosePollAndAbandonRacePreserveTheExactAnswer() throws {
        let (runtime, launch) = try fixture()
        let input = question(launch), id = input["request_id"]!.text!
        _ = try ask(runtime, input)
        _ = try runtime.resolveDecision(id, generation: launch.id, action: "choose", optionID: "disk", instruction: "한글\n'quote';", locale: "ko")
        let poll = try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(id)]))
        XCTAssertEqual(poll["status"], .string("resolved"))
        XCTAssertEqual(poll["response"]?["action"], .string("choose"))
        XCTAssertEqual(poll["response"]?["selected_option_id"], .string("disk"))
        XCTAssertEqual(poll["response"]?["instruction"], .string("한글\n'quote';"))
        XCTAssertEqual(poll["response"]?["instruction_locale"], .string("ko"))
        let abandoned = try runtime.decisionAdapter(.object(["type": .string("abandon"), "request_id": .string(id)]))
        XCTAssertEqual(abandoned, poll)
        XCTAssertThrowsError(try runtime.resolveDecision(id, generation: launch.id, action: "choose", optionID: "memory"))
        XCTAssertEqual(try runtime.state().events.map(\.activity.reason), ["Waiting for a decision", ""])
    }

    // Implements: FR-DECISION-2, FR-DECISION-3
    func testPendingQuestionBlocksItsPaneUntilAnsweredEvenWhileTheAgentPolls() throws {
        let (runtime, launch) = try fixture()
        let input = question(launch), id = input["request_id"]!.text!
        func activity() throws -> Activity { try XCTUnwrap(runtime.state().sessions.first { $0.id == launch.paneID }).activity }
        func hook(_ event: String) throws {
            let payload: [String: JSONValue] = ["session_id": .string(launch.providerSessionID!), "hook_event_name": .string(event),
                                                "cwd": .string(launch.cwd), "tool_name": .string("Bash")]
            try runtime.recordAgentHook(paneID: launch.paneID, generation: launch.id, provider: .codex, data: JSONEncoder().encode(payload))
        }
        _ = try ask(runtime, input)
        XCTAssertEqual(try activity().state, .blocked)
        XCTAssertEqual(try activity().reason, "Waiting for a decision")
        try hook("PreToolUse")
        XCTAssertEqual(try activity().state, .blocked, "Polling must not hide the pending question")
        _ = try ask(runtime, input)
        XCTAssertEqual(try runtime.state().events.count, 1, "A repeated submit must not notify twice")
        _ = try runtime.resolveDecision(id, generation: launch.id, action: "choose", optionID: "disk")
        XCTAssertEqual(try activity().state, .running)
        let second = question(launch)
        _ = try ask(runtime, second)
        XCTAssertEqual(try activity().state, .blocked)
        _ = try runtime.decisionAdapter(.object(["type": .string("abandon"), "request_id": second["request_id"]!]))
        XCTAssertEqual(try activity().state, .running)
        try hook("PreToolUse")
        XCTAssertEqual(try activity().state, .running)
    }

    // Implements: FR-DECISION-3
    func testOtherInputCancelAndAbandonAreDistinct() throws {
        let (runtime, launch) = try fixture()
        let input = question(launch), id = input["request_id"]!.text!
        _ = try ask(runtime, input)
        _ = try runtime.resolveDecision(id, generation: launch.id, action: "revise", instruction: "Use SQLite instead.", locale: "en")
        let revised = try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(id)]))
        XCTAssertEqual(revised["response"]?["action"], .string("revise"))
        XCTAssertEqual(revised["response"]?["revision_kind"], .string("discuss"))
        let cancelled = question(launch), cancelID = cancelled["request_id"]!.text!
        _ = try ask(runtime, cancelled)
        _ = try runtime.resolveDecision(cancelID, generation: launch.id, action: "cancel")
        XCTAssertEqual(try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(cancelID)]))["response"]?["action"], .string("cancel"))
        let abandoned = question(launch), abandonID = abandoned["request_id"]!.text!
        _ = try ask(runtime, abandoned)
        XCTAssertEqual(try runtime.decisionAdapter(.object(["type": .string("abandon"), "request_id": .string(abandonID)]))["status"], .string("abandoned"))
        XCTAssertThrowsError(try runtime.resolveDecision(abandonID, generation: launch.id, action: "choose", optionID: "disk"))
        try runtime.deleteDecision(abandonID)
        XCTAssertFalse(try runtime.decisionInbox().contains { $0.id == abandonID })
    }

    // Implements: FR-DECISION-2
    func testNewLaunchCannotAnswerStaleDecision() throws {
        let (runtime, launch) = try fixture()
        let input = question(launch), id = input["request_id"]!.text!
        _ = try ask(runtime, input)
        try runtime.update { $0.agentLaunches[0].id = UUID().uuidString.lowercased() }
        XCTAssertThrowsError(try runtime.resolveDecision(id, generation: launch.id, action: "choose", optionID: "disk"))
        XCTAssertEqual(try runtime.decisionAdapter(.object(["type": .string("poll"), "request_id": .string(id)]))["status"], .string("abandoned"))
    }

    // Implements: FR-DECISION-1
    func testInvalidPayloadBoundsUnsupportedDiscussionAndSymlinkStorage() throws {
        let (runtime, launch) = try fixture()
        var input = question(launch)
        input["question"] = .string(String(repeating: "x", count: 32_769))
        XCTAssertEqual(try ask(runtime, input)["error"], .string("INVALID_REQUEST"))
        input = question(launch)
        input["understanding"] = .object([:])
        XCTAssertEqual(try ask(runtime, input)["error"], .string("UNSUPPORTED_FEATURE"))
        XCTAssertEqual(try runtime.decisionAdapter(.object(["type": .string("lease_context")]))["error"], .string("UNSUPPORTED_FEATURE"))
        let target = runtime.root.appendingPathComponent("untouched")
        try Data("private fixture".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: runtime.root.appendingPathComponent("decision-inbox.json"), withDestinationURL: target)
        XCTAssertThrowsError(try runtime.decisionInbox())
        XCTAssertEqual(try String(contentsOf: target), "private fixture")
    }

    // Implements: FR-DECISION-1, FR-DECISION-2
    func testNativePromptHookProvidesExactBindingWithoutGlobalPlugin() throws {
        let (runtime, launch) = try fixture()
        let data = try JSONEncoder().encode(["hook_event_name": "UserPromptSubmit", "session_id": launch.providerSessionID!, "cwd": launch.cwd])
        let result = try runtime.decisionHookOutput(paneID: launch.paneID, generation: launch.id, provider: .codex, data: data)
        let context = try XCTUnwrap(result?["hookSpecificOutput"]?["additionalContext"]?.text)
        XCTAssertTrue(context.contains(launch.providerSessionID!))
        XCTAssertTrue(context.contains(launch.cwd))
        XCTAssertTrue(context.contains("easydecision-adapter ask"))
        XCTAssertNil(try runtime.decisionHookOutput(paneID: launch.paneID, generation: "stale", provider: .codex, data: data))
    }
}
