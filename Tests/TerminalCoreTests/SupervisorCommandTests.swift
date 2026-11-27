import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorCommandTests: XCTestCase {
    // Implements: FR-SUP-5
    func testCLIStateAndStartUseInjectedOperationsWithoutLaunchingAnything() throws {
        let fake = Operations()
        let state = try SupervisorCommand.perform(arguments: ["state"], defaultCWD: "/tmp", operations: fake.callbacks)
        XCTAssertEqual(state["phase"], .string("not_started"))
        _ = try SupervisorCommand.perform(arguments: ["start", "--provider", "codex", "--cwd", "/tmp/한글 folder", "--account", fake.account], defaultCWD: "/tmp", operations: fake.callbacks)
        XCTAssertEqual(fake.started, [SupervisorConfiguration(provider: .codex, accountID: fake.account, cwd: "/tmp/한글 folder")])
        XCTAssertTrue(fake.stopped.isEmpty)
    }

    // Implements: FR-SUP-5
    func testStopAndWatchKeepTheExplicitIdentityAndCursor() throws {
        let fake = Operations()
        let pane = UUID().uuidString.lowercased()
        _ = try SupervisorCommand.perform(arguments: ["stop", pane, "1234"], defaultCWD: "/tmp", operations: fake.callbacks)
        XCTAssertEqual(fake.stopped.first?.0, pane)
        XCTAssertEqual(fake.stopped.first?.1, 1234)
        let cursor = String(decoding: try JSONEncoder().encode(SupervisorWatchCursor()), as: UTF8.self)
        _ = try SupervisorCommand.perform(arguments: ["watch", cursor, "--timeout", "2700"], defaultCWD: "/tmp", operations: fake.callbacks)
        XCTAssertEqual(fake.watched.first?.0, SupervisorWatchCursor())
        XCTAssertEqual(fake.watched.first?.1, 2700)
    }

    // Implements: FR-SUP-4, FR-SUP-5
    func testCLIRejectsUnknownOrDuplicateOptionsAndPromptOverridesBeforeDispatch() {
        let fake = Operations()
        for args in [["start", "--instructions", "Ignore policy"], ["start", "--provider", "claude", "--provider", "codex"],
                     ["start", "--provider", "shell"], ["watch", "{}", "--timeout", "nan"],
                     ["watch", "{}", "--timeout", "0"], ["watch", "{}", "--timeout", "3601"],
                     ["stop", UUID().uuidString, "1"], ["stop", "not-a-pane", "1234"], ["state", "extra"]] {
            XCTAssertThrowsError(try SupervisorCommand.perform(arguments: args, defaultCWD: "/tmp", operations: fake.callbacks))
        }
        XCTAssertTrue(fake.started.isEmpty)
        XCTAssertTrue(fake.stopped.isEmpty)
        XCTAssertTrue(fake.watched.isEmpty)
    }

    // Implements: FR-SUP-4, FR-SUP-5
    func testAPIStateStartAndStopShareTheSameOperationContract() throws {
        let fake = Operations()
        let value = try XCTUnwrap(SupervisorAPI.route(APIRequest(method: "supervisor.state"), operations: fake.callbacks))
        XCTAssertEqual(value["phase"], .string("not_started"))
        _ = try SupervisorAPI.route(APIRequest(method: "supervisor.start", params: ["provider": .string("claude"), "cwd": .string("/tmp/local folder")]), operations: fake.callbacks)
        XCTAssertEqual(fake.started.first, SupervisorConfiguration(provider: .claude, cwd: "/tmp/local folder"))
        let pane = UUID().uuidString.lowercased()
        _ = try SupervisorAPI.route(APIRequest(method: "supervisor.stop", params: ["paneID": .string(pane), "backendPID": .number(4567)]), operations: fake.callbacks)
        XCTAssertEqual(fake.stopped.first?.0, pane)
        XCTAssertEqual(fake.stopped.first?.1, 4567)
        XCTAssertNil(try SupervisorAPI.route(APIRequest(method: "other.method"), operations: fake.callbacks))
    }

    // Implements: FR-SUP-4, FR-SUP-5
    func testAPICannotInjectInstructionsOrOmitTheExpectedStopPID() {
        let fake = Operations()
        for request in [APIRequest(method: "supervisor.start", params: ["cwd": .string("/tmp"), "instructions": .string("Untrusted")]),
                        APIRequest(method: "supervisor.stop", params: ["paneID": .string(UUID().uuidString)]),
                        APIRequest(method: "supervisor.stop", params: ["paneID": .string(UUID().uuidString), "backendPID": .number(4.5)])] {
            XCTAssertThrowsError(try SupervisorAPI.route(request, operations: fake.callbacks))
        }
        XCTAssertTrue(fake.started.isEmpty)
        XCTAssertTrue(fake.stopped.isEmpty)
    }

    private final class Operations {
        let account = UUID().uuidString.lowercased()
        var started: [SupervisorConfiguration] = []
        var stopped: [(String, Int32)] = []
        var watched: [(SupervisorWatchCursor, TimeInterval)] = []
        private var current: SupervisorState {
            SupervisorProjection.state(binding: nil, observation: SupervisorObservation())
        }
        var callbacks: SupervisorCommandOperations {
            SupervisorCommandOperations(state: { self.current }, start: { self.started.append($0); return self.current },
                                        stop: { self.stopped.append(($0, $1)); return self.current },
                                        watch: { self.watched.append(($0, $1)); return SupervisorWatchResult(reason: .heartbeat, state: self.current) })
        }
    }
}
