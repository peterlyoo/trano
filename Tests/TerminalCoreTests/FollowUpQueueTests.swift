import XCTest
import Darwin
@testable import TerminalCore

final class FollowUpQueueTests: XCTestCase {
    // Implements: FR-QUEUE-2
    func testRecoveredToolErrorStillAllowsTheTurnsFinalDone() {
        var turn = FollowUpTurn(paneID: "pane", generation: "generation")
        turn.observe(event: "UserPromptSubmit", originPID: 10)
        turn.observe(event: "PostToolUseFailure", originPID: 10)
        turn.observe(event: "PreModelRequest", originPID: 10)
        turn.observe(event: "Stop", originPID: 10)
        XCTAssertNotNil(turn.completionID)
    }

    // Implements: FR-QUEUE-1
    func testCRUDPersistsExactUnicodeMultilineFIFOAndDoesNotLeakIntoEvents() throws {
        try withRuntime { runtime, pane in
            let text = "  한글".decomposedStringWithCanonicalMapping + " 👩🏽‍💻\n'quoted'; $()\n"
            let first = try runtime.addFollowUp(paneID: pane.id, text: text)
            let second = try runtime.addFollowUp(paneID: pane.id, text: "second")
            XCTAssertEqual(first.status, .needsReview)
            XCTAssertNil(first.generation)
            XCTAssertNotNil(first.message)
            let reopened = try TerminalRuntime(root: runtime.root)
            XCTAssertEqual(try reopened.followUps(paneID: pane.id).map(\.id), [first.id, second.id])
            XCTAssertEqual(try reopened.followUps(paneID: pane.id).first?.text.utf8.map { $0 }, Array(text.utf8))
            let edited = try reopened.updateFollowUp(id: first.id, text: "수정\nline two\n")
            XCTAssertEqual(edited.id, first.id)
            XCTAssertEqual(edited.createdAt, first.createdAt)
            XCTAssertEqual(try reopened.followUps(paneID: pane.id).map(\.id), [first.id, second.id])
            try reopened.removeFollowUp(id: first.id)
            XCTAssertEqual(try reopened.followUps(paneID: pane.id).map(\.id), [second.id])
            XCTAssertTrue(try reopened.state().events.isEmpty)
            XCTAssertThrowsError(try reopened.updateFollowUp(id: first.id, text: "missing"))
            XCTAssertThrowsError(try reopened.followUps(paneID: UUID().uuidString))
        }
    }

    // Implements: FR-QUEUE-1
    func testValidationBoundsUTF8AndRejectsTerminalControlsWithoutChangingQueue() throws {
        try withRuntime { runtime, pane in
            for text in ["", " \n\t ", "a\0b", "a\r\nb", "\u{1b}[200~escape", "\u{7}", "\u{9b}31m", String(repeating: "가", count: 21846)] {
                XCTAssertThrowsError(try runtime.addFollowUp(paneID: pane.id, text: text))
            }
            let boundary = String(repeating: "a", count: 65536)
            let value = try runtime.addFollowUp(paneID: pane.id, text: boundary)
            XCTAssertEqual(value.text.utf8.count, 65536)
            XCTAssertThrowsError(try runtime.updateFollowUp(id: value.id, text: "\u{1b}]title\u{7}"))
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).first?.text, boundary)
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).count, 1)
        }
    }

    // Implements: FR-QUEUE-1
    func testLegacyStateDecodesWithEmptyQueueAndSharedAPICRUD() throws {
        try withRuntime { runtime, pane in
            let encoded = try JSONEncoder().encode(runtime.state())
            var object = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
            object.removeValue(forKey: "followUpInputs")
            object.removeValue(forKey: "followUpTurns")
            object.removeValue(forKey: "followUpPasteStates")
            let legacy = try JSONDecoder().decode(RuntimeState.self, from: JSONEncoder().encode(object))
            XCTAssertTrue(legacy.followUpInputs.isEmpty)
            let service = APIService(runtime: runtime)
            let add = service.route(APIRequest(method: "followups.add", params: ["paneID": .string(pane.id), "text": .string("하나\n둘")]))
            XCTAssertNil(add.error)
            let id = try XCTUnwrap(add.result?["id"]?.text)
            let edit = service.route(APIRequest(method: "followups.update", params: ["id": .string(id), "text": .string("edited")]))
            XCTAssertEqual(edit.result?["text"]?.text, "edited")
            let list = service.route(APIRequest(method: "followups.list", params: ["paneID": .string(pane.id)]))
            XCTAssertEqual(list.result?.array?.count, 1)
            XCTAssertNil(service.route(APIRequest(method: "followups.remove", params: ["id": .string(id)])).error)
            XCTAssertTrue(try runtime.followUps(paneID: pane.id).isEmpty)
        }
    }

    // Implements: FR-QUEUE-2, FR-QUEUE-3
    func testReplacedGenerationRequiresExplicitEditToRebind() throws {
        try withRuntime { runtime, pane in
            let first = try runtime.beginAgentLaunch(paneID: pane.id, provider: .claude, cwd: runtime.root.path)
            let input = try runtime.addFollowUp(paneID: pane.id, text: "preserved")
            XCTAssertEqual(input.generation, first.id)
            XCTAssertEqual(input.status, .pending)
            try runtime.endAgentLaunch(paneID: pane.id, generation: first.id, normalExit: true)
            let second = try runtime.beginAgentLaunch(paneID: pane.id, provider: .codex, cwd: runtime.root.path)
            let stale = try XCTUnwrap(runtime.followUps(paneID: pane.id).first)
            XCTAssertEqual(stale.text, "preserved")
            XCTAssertEqual(stale.status, .needsReview)
            XCTAssertEqual(stale.generation, first.id)
            try runtime.processPendingFollowUps()
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).first?.status, .needsReview)
            let rebound = try runtime.updateFollowUp(id: stale.id, text: stale.text)
            XCTAssertEqual(rebound.generation, second.id)
            XCTAssertEqual(rebound.status, .pending)
        }
    }

    // Implements: FR-QUEUE-2
    func testUntrustedExplicitOSCChildAndOriginlessDoneNeverArmDelivery() throws {
        try withRuntime { runtime, pane in
            let launch = try runtime.beginAgentLaunch(paneID: pane.id, provider: .claude, cwd: runtime.root.path)
            try runtime.recordAgentProcess(paneID: pane.id, generation: launch.id, pid: getpid())
            _ = try runtime.addFollowUp(paneID: pane.id, text: "do not send")
            try runtime.report(pane.id, state: .done, agent: .claude)
            try runtime.report(pane.id, report: ActivityReport(state: .done, agent: .claude, reason: "", clearsActive: false, generation: launch.id))
            let session = UUID().uuidString
            for kind in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "StopFailure", "Stop"] {
                let event = try JSONEncoder().encode(["session_id": session, "cwd": runtime.root.path, "hook_event_name": kind])
                try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: event)
                try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: event, originPID: getpid())
            }
            try runtime.processPendingFollowUps()
            XCTAssertTrue(try runtime.state().followUpTurns.isEmpty)
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).count, 1)
        }
    }

    // Implements: FR-QUEUE-2, FR-QUEUE-3
    func testCompletionReducerConsumesOneTurnAndRejectsDuplicateBlockedOrStaleDone() {
        var turn = FollowUpTurn(paneID: "pane", generation: "generation")
        turn.observe(event: "Stop", originPID: 10)
        XCTAssertNil(turn.completionID)
        turn.observe(event: "UserPromptSubmit", originPID: 10)
        turn.observe(event: "PermissionRequest", originPID: 10)
        XCTAssertNil(turn.completionID)
        turn.observe(event: "StopFailure", originPID: 10)
        XCTAssertNil(turn.completionID)
        turn.observe(event: "UserPromptSubmit", originPID: 10)
        turn.observe(event: "PreToolUse", originPID: 10)
        turn.observe(event: "Stop", originPID: 10)
        let completion = turn.completionID
        XCTAssertNotNil(completion)
        turn.observe(event: "Stop", originPID: 11)
        XCTAssertEqual(turn.completionID, completion)
        turn.consumedCompletionID = completion
        turn.observe(event: "Stop", originPID: 12)
        XCTAssertEqual(turn.completionID, turn.consumedCompletionID)
        turn.observe(event: "UserPromptSubmit", originPID: 12)
        XCTAssertNil(turn.completionID)
        turn.observe(event: "Stop", originPID: 12)
        XCTAssertNotEqual(turn.completionID, completion)
    }

    // Implements: FR-QUEUE-3
    func testInterruptedSendingBecomesReviewAndCannotBeRetriedAutomatically() throws {
        try withRuntime { runtime, pane in
            let value = try runtime.addFollowUp(paneID: pane.id, text: "ambiguous")
            try runtime.update { state in
                state.followUpInputs[0].status = .sending
            }
            let reopened = try TerminalRuntime(root: runtime.root)
            try reopened.processPendingFollowUps()
            try reopened.processPendingFollowUps()
            let held = try XCTUnwrap(reopened.followUps(paneID: pane.id).first)
            XCTAssertEqual(held.id, value.id)
            XCTAssertEqual(held.text, value.text)
            XCTAssertEqual(held.status, .needsReview)
            XCTAssertTrue(held.message?.contains("delivery") == true)
        }
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-3
    func testSendingReservationRejectsEditsAndDeletesUntilHelperMarksItForReview() throws {
        try withRuntime { runtime, pane in
            let input = try runtime.addFollowUp(paneID: pane.id, text: "reserved")
            try runtime.update { $0.followUpInputs[0].status = .sending }
            XCTAssertThrowsError(try runtime.updateFollowUp(id: input.id, text: "changed"))
            XCTAssertThrowsError(try runtime.removeFollowUp(id: input.id))
            let service = APIService(runtime: runtime)
            defer { service.stop() }
            try service.start()
            let deadline = Date().addingTimeInterval(3)
            while try runtime.followUps(paneID: pane.id).first?.status == .sending, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).first?.status, .needsReview)
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).first?.text, "reserved")
            try runtime.removeFollowUp(id: input.id)
            XCTAssertTrue(try runtime.followUps(paneID: pane.id).isEmpty)
        }
    }

    // Implements: FR-QUEUE-1
    func testPerPaneCapacityRejectsOverflowWithoutLosingExistingInputs() throws {
        try withRuntime { runtime, pane in
            for index in 0..<100 { _ = try runtime.addFollowUp(paneID: pane.id, text: "input \(index)") }
            XCTAssertThrowsError(try runtime.addFollowUp(paneID: pane.id, text: "overflow"))
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).count, 100)
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).last?.text, "input 99")
        }
    }

    // Implements: FR-QUEUE-2, FR-QUEUE-3
    func testRemoteQueuePersistsWithActionableUnsupportedReviewState() throws {
        try withRuntime { runtime, pane in
            try runtime.update { $0.sessions[0].remote = RemoteReference(hostID: "fixture", sessionID: pane.id) }
            let value = try runtime.addFollowUp(paneID: pane.id, text: "never type this in SSH")
            XCTAssertEqual(value.status, .needsReview)
            XCTAssertTrue(value.message?.contains("remote") == true)
            try runtime.processPendingFollowUps()
            XCTAssertEqual(try runtime.followUps(paneID: pane.id).first?.text, value.text)
        }
    }

    // Implements: FR-QUEUE-1
    func testTerminationRemovesOnlyThatPanesQueue() throws {
        try withRuntime { runtime, _ in
            let live = try runtime.create(title: "Disposable", cwd: runtime.root.path, shell: "/bin/sh", arguments: ["-c", "exec sleep 30"])
            _ = try runtime.addFollowUp(paneID: live.id, text: "one")
            let other = try XCTUnwrap(runtime.state().sessions.first(where: { $0.id != live.id }))
            let retained = try runtime.addFollowUp(paneID: other.id, text: "two")
            try runtime.terminate(live.id)
            XCTAssertEqual(try runtime.state().followUpInputs.map(\.id), [retained.id])
        }
    }

    // Implements: FR-QUEUE-2, FR-QUEUE-3
    func testBracketedPasteScannerHandlesSplitControlsAndIgnoresOrdinaryOutput() {
        var scanner = FollowUpPasteScanner()
        XCTAssertTrue(scanner.feed(Data("ordinary [?2004h".utf8)).isEmpty)
        XCTAssertTrue(scanner.feed(Data([27, 91, 63, 50])).isEmpty)
        XCTAssertEqual(scanner.feed(Data("004h".utf8)), [true])
        XCTAssertEqual(scanner.feed(Data("\u{1b}[?2004l\u{1b}[?2004h".utf8)), [false, true])
        XCTAssertTrue(scanner.feed(Data("\u{1b}[?20040h".utf8)).isEmpty)
    }

    // Implements: FR-QUEUE-2, FR-QUEUE-3
    func testBracketedPasteScannerIgnoresTerminalStringsAndRecognizesResetAndCombinedModes() {
        var scanner = FollowUpPasteScanner()
        for output in ["\u{1b}]0;title \u{1b}[?2004h\u{7}", "\u{1b}Ppayload \u{1b}[?2004h\u{1b}\\", "\u{1b}_payload \u{1b}[?2004l\u{1b}\\"] {
            XCTAssertTrue(scanner.feed(Data(output.utf8)).isEmpty)
        }
        XCTAssertEqual(scanner.feed(Data("\u{1b}[?25;2004h".utf8)), [true])
        XCTAssertEqual(scanner.feed(Data("\u{1b}c".utf8)), [false])
        XCTAssertEqual(scanner.feed(Data("\u{1b}[?2004;1000l".utf8)), [false])
        XCTAssertTrue(scanner.feed(Data("\u{1b}[2004h\u{1b}[?2004:1h".utf8)).isEmpty)
    }

    private func withRuntime(_ body: (TerminalRuntime, TerminalSession) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/tmp/trano-fu-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer {
            for pane in (try? runtime.list()) ?? [] where pane.pid != 0 { try? runtime.terminate(pane.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Follow-ups", cwd: root.path, pid: 0, alive: false)
        try runtime.update { $0.sessions.append(pane) }
        try body(runtime, pane)
    }
}
