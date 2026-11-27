import XCTest
@testable import TerminalCore

final class AttentionSummaryTests: XCTestCase {
    private func payload(_ json: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    func testPermissionRequestSummarizesToolAndInput() throws {
        let result = AttentionSummary.activity(event: "PermissionRequest", payload: try payload(#"{"tool_name":"Bash","tool_input":{"command":"grep ACTKEY /tmp/log\n| tail -5"}}"#))
        XCTAssertEqual(result?.state, .blocked)
        XCTAssertEqual(result?.reason, "approve Bash: grep ACTKEY /tmp/log | tail -5")
        XCTAssertEqual(AttentionSummary.activity(event: "PermissionRequest", payload: try payload(#"{"tool_name":"Edit","tool_input":{"file_path":"/a/b.swift"}}"#))?.reason, "approve Edit: /a/b.swift")
        XCTAssertEqual(AttentionSummary.activity(event: "PermissionRequest", payload: [:])?.reason, "approve tool")
    }

    func testQuestionToolBlocksUntilAnsweredAndOrdinaryToolsPassThrough() throws {
        let ask = try payload(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which scope?","options":[]}]}}"#)
        XCTAssertEqual(AttentionSummary.activity(event: "PreToolUse", payload: ask)?.state, .blocked)
        XCTAssertEqual(AttentionSummary.activity(event: "PreToolUse", payload: ask)?.reason, "answer: Which scope?")
        XCTAssertEqual(AttentionSummary.activity(event: "PostToolUse", payload: ask)?.state, .running)
        XCTAssertNil(AttentionSummary.activity(event: "PreToolUse", payload: try payload(#"{"tool_name":"Bash"}"#)))
    }

    func testQuestionAndDecisionNameTheirOptionsLikeRex() throws {
        let ask = try payload(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which scope?","options":[{"label":"Run in background (Recommended)"},{"label":"Wait for results"}]}]}}"#)
        XCTAssertEqual(AttentionSummary.activity(event: "PreToolUse", payload: ask)?.reason,
                       "answer: Which scope? (Run in background (Recommended) · Wait for results)")
        let decision = try JSONDecoder().decode(DecisionQuestion.self, from: Data(#"""
        {"requestID":"r","threadID":"t","source":{"agent":"claude","sessionID":"s","workspace":"/w"},
         "question":{"en":"Ship it?","ko":"배포할까요?"},
         "options":[{"id":"yes","label":{"en":"Yes","ko":"예"},"description":{"en":"","ko":""}},
                    {"id":"no","label":{"en":"No","ko":"아니요"},"description":{"en":"","ko":""}}]}
        """#.utf8))
        XCTAssertEqual(AttentionSummary.decision(decision, locale: "ko"), "answer: 배포할까요? (예 · 아니요)")
        XCTAssertEqual(AttentionSummary.decision(decision, locale: "en"), "answer: Ship it? (Yes · No)")
    }

    func testCompletionNamesTheSessionTitleTheAgentSet() {
        XCTAssertEqual(AttentionSummary.completion(terminalTitle: "로그인 버그 수정"), "로그인 버그 수정")
        XCTAssertEqual(AttentionSummary.completion(terminalTitle: "  Fix login\nbug  "), "Fix loginbug")
        XCTAssertEqual(AttentionSummary.completion(terminalTitle: nil), "Task completed")
        XCTAssertEqual(AttentionSummary.completion(terminalTitle: " \u{7} "), "Task completed")
        XCTAssertLessThanOrEqual(AttentionSummary.completion(terminalTitle: String(repeating: "가", count: 500)).count, AttentionSummary.limit)
    }

    func testCompletionPrefersTheAgentsTurnSummary() {
        XCTAssertEqual(AttentionSummary.completion(reason: "Conflicts resolved; CI green", terminalTitle: "로그인 버그 수정"),
                       "Conflicts resolved; CI green")
        XCTAssertEqual(AttentionSummary.completion(reason: "  ", terminalTitle: "로그인 버그 수정"), "로그인 버그 수정")
    }

    func testBareCompletionWaitsForTheSummaryThatFollowsIt() {
        let now = Date(timeIntervalSince1970: 1000)
        func event(_ revision: Int, _ state: ActivityState, _ source: String, _ reason: String, age: TimeInterval, agent: AgentKind = .claude) -> ActivityEvent {
            var activity = Activity(); activity.state = state; activity.source = source; activity.reason = reason
            activity.updatedAt = now.addingTimeInterval(-age)
            return ActivityEvent(revision: revision, sessionID: "p", title: "project", activity: activity, agent: agent)
        }
        XCTAssertEqual(ActivityNotificationBacklog.wait(for: [event(1, .done, "hook", "", age: 0.5)], now: now) ?? 0, 2.5, accuracy: 0.001)
        XCTAssertNil(ActivityNotificationBacklog.wait(for: [event(1, .done, "hook", "", age: 3.5)], now: now), "no summary came: deliver the bare one")
        XCTAssertNil(ActivityNotificationBacklog.wait(for: [event(1, .done, "osc7501", "tests green", age: 0)], now: now))
        XCTAssertNil(ActivityNotificationBacklog.wait(for: [event(1, .done, "shell", "", age: 0, agent: .shell)], now: now))
        let pair = [event(1, .done, "hook", "", age: 2.3), event(2, .done, "osc7501", "CI green", age: 0)]
        XCTAssertEqual(ActivityNotificationBacklog.deliverable(pair, now: now).map(\.activity.reason), ["CI green"],
                       "the summary replaces the bare completion of the same session")
        XCTAssertEqual(ActivityNotificationBacklog.wait(for: [event(1, .blocked, "osc7501", "permission prompt", age: 0.2)], now: now) ?? 0, 0.8, accuracy: 0.001)
    }

    func testNotificationOnlyBlocksForPermissionAndElicitation() throws {
        XCTAssertEqual(AttentionSummary.activity(event: "Notification", payload: try payload(#"{"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#))?.reason, "Claude needs your permission to use Bash")
        XCTAssertNil(AttentionSummary.activity(event: "Notification", payload: try payload(#"{"notification_type":"idle_prompt","message":"waiting"}"#)))
    }

    func testLongReasonsAreBounded() {
        XCTAssertEqual(AttentionSummary.permission(tool: "Bash", input: .object(["command": .string(String(repeating: "x", count: 1000))])).count, AttentionSummary.limit)
    }

    func testFocusedPaneSuppressesBannerAndSoundOnlyWhileActive() {
        var preferences = NotificationPreferences()
        preferences.playSounds = true
        let watching = NotificationPolicy.effects(kind: .activity, activity: .blocked, paneID: "p1", preferences: preferences,
                                                  legacyMasterEnabled: true, context: NotificationContext(applicationActive: true, focusedPaneID: "p1"))
        XCTAssertFalse(watching.systemNotification); XCTAssertNil(watching.soundVolume)
        let other = NotificationPolicy.effects(kind: .activity, activity: .blocked, paneID: "p2", preferences: preferences,
                                               legacyMasterEnabled: true, context: NotificationContext(applicationActive: true, focusedPaneID: "p1"))
        let inactive = NotificationPolicy.effects(kind: .activity, activity: .blocked, paneID: "p1", preferences: preferences,
                                                  legacyMasterEnabled: true, context: NotificationContext(applicationActive: false, focusedPaneID: "p1"))
        XCTAssertEqual(other.systemNotification, inactive.systemNotification)
        XCTAssertEqual(other.soundVolume, inactive.soundVolume)
    }

    func testPresenceIgnoresDeadOrInactiveWriters() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("trano-presence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try InterfacePresence.write(InterfacePresence(pid: getpid(), focusedPaneID: "p1"), root: root)
        XCTAssertEqual(InterfacePresence.focusedPane(root: root) { _ in true }, "p1")
        XCTAssertNil(InterfacePresence.focusedPane(root: root) { _ in false })
        try InterfacePresence.write(InterfacePresence(pid: 999_999, focusedPaneID: "p1"), root: root)
        XCTAssertNil(InterfacePresence.focusedPane(root: root) { _ in true })
    }
}
