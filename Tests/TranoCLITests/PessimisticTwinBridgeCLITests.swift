import Foundation
import XCTest
import TerminalCore
@testable import TranoCLI

final class PessimisticTwinBridgeCLITests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-6, FR-TWIN-10
    private let runID = "22222222-2222-4222-8222-222222222222"
    private let environment = ["TRANO_TWIN_API_SOCKET": "/fixture/scoped.sock", "TRANO_TWIN_ROUND": "2"]
    private func response(_ result: JSONValue = .object(["status": .string("ok")]), error: String? = nil) throws -> APIResponse {
        var object: [String: JSONValue] = ["apiVersion": .number(1), "result": result]
        if let error { object["error"] = .string(error) }
        return try JSONDecoder().decode(APIResponse.self, from: JSONEncoder().encode(object))
    }
    func testHandlesBridgeCommandsAndRejectsBootstrapWithoutInterception() {
        for command in ["report", "respond", "hook", "diff", "commit"] { XCTAssertTrue(TwinBridgeCLI.handles(["twin", command, runID])) }
        XCTAssertFalse(TwinBridgeCLI.handles(["twin", "run", "ticket", "nonce"]))
        XCTAssertFalse(TwinBridgeCLI.handles(["api", "twins.report"]))
        XCTAssertFalse(TwinBridgeCLI.handles([]))
    }
    func testReportRoutesExactUnicodeEnvelopeWithoutRuntimeOrFilesystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("absent-twin-cli-" + UUID().uuidString)
        let envelope: JSONValue = .object(["status": .string("working"), "rationale": .string("한글과 emoji 🐈, 줄\n바꿈"), "changed_files": .array([.string("경로/파일.swift")])])
        let data = try JSONEncoder().encode(envelope)
        var requests: [APIRequest] = [], output = Data()
        let code = try TwinBridgeCLI.execute(["twin", "report", runID], environment: environment.merging(["TRANO_DATA_DIR": root.path]) { _, new in new }, readInput: { data }, call: { path, request in
            XCTAssertEqual(path, "/fixture/scoped.sock"); requests.append(request); return try self.response(.object(["receipt": .string("저장됨")]))
        }, write: { output.append($0) })
        XCTAssertEqual(code, 0); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "twins.report")
        XCTAssertEqual(requests[0].params, ["runID": .string(runID), "round": .number(2), "envelope": envelope])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output), .object(["receipt": .string("저장됨")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testSourceRespondUsesExplicitRoundAndDataRootSocketWithNoInheritedScope() throws {
        var called = false
        let envelope: JSONValue = .object(["status": .string("no_further_improvement"), "rationale": .string("수용"), "changed_files": .array([])])
        _ = try TwinBridgeCLI.execute(["twin", "respond", runID, "--round", "3"], environment: ["TRANO_DATA_DIR": "/fixture/source-root", "TRANO_TWIN_ROUND": "1"], readInput: { try! JSONEncoder().encode(envelope) }, call: { path, request in
            called = true; XCTAssertEqual(path, "/fixture/source-root/api.sock"); XCTAssertEqual(request.method, "twins.respond"); XCTAssertEqual(request.params["round"], .number(3)); return try self.response()
        }, write: { _ in })
        XCTAssertTrue(called)
    }
    func testDefaultSocketUsesHomeWithoutConsultingRuntimeOrGlobalSocketVariables() throws {
        _ = try TwinBridgeCLI.execute(["twin", "diff", runID, "--round", "1"], environment: ["HOME": "/fixture/home", "TRANO_API_SOCKET": "/untrusted/global.sock", "EASYDECISION_SOCKET": "/untrusted/other.sock"], call: { path, request in
            XCTAssertEqual(path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/trano/api.sock").path); XCTAssertEqual(request.method, "twins.diff"); return try self.response(.object(["diff": .string("diff\n끝")]))
        }, write: { XCTAssertEqual(String(decoding: $0, as: UTF8.self), "diff\n끝") })
    }
    func testHookEmitsRawProviderDecisionOrNothingForNull() throws {
        let payload: JSONValue = .object(["hook_event_name": .string("PreToolUse"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("echo '한글'")])])
        for result in [JSONValue.null, .object(["decision": .string("block"), "reason": .string("사용자 결정 필요")])] {
            var output = Data()
            _ = try TwinBridgeCLI.execute(["twin", "hook", runID], environment: environment, readInput: { try! JSONEncoder().encode(payload) }, call: { _, request in
                XCTAssertEqual(request.method, "twins.hook"); XCTAssertEqual(request.params["payload"], payload); return try self.response(result)
            }, write: { output.append($0) })
            if result == .null { XCTAssertTrue(output.isEmpty) }
            else { XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output), result) }
        }
    }
    func testDiffAndCommitDoNotReadStdinAndCommitPreservesExactMessage() throws {
        let message = "수정: '인용' $변수\n검증 결과"
        for command in ["diff", "commit"] {
            let arguments = ["twin", command, runID] + (command == "commit" ? ["--message", message] : [])
            _ = try TwinBridgeCLI.execute(arguments, environment: environment, readInput: { XCTFail("Unexpected stdin read"); return Data() }, call: { _, request in
                XCTAssertEqual(request.method, "twins." + command)
                XCTAssertEqual(request.params["message"], command == "commit" ? .string(message) : nil)
                return try self.response(command == "diff" ? .object(["diff": .string("")]) : .object(["commit": .string("abc")]))
            }, write: { _ in })
        }
    }
    func testMalformedArgumentsFailBeforeAnyInputOrAPI() {
        let cases = [
            ["twin", "hook"], ["twin", "hook", "not-a-uuid"], ["twin", "terminate", runID], ["api", "twins.report", runID],
            ["twin", "diff", runID, "--round", "0"], ["twin", "diff", runID, "--round", "9"], ["twin", "diff", runID, "--round"],
            ["twin", "diff", runID, "--round", "1", "--round", "2"], ["twin", "diff", runID, "--message", "injected"],
            ["twin", "commit", runID], ["twin", "commit", runID, "--message", ""], ["twin", "commit", runID, "--message", "bad\0message"],
            ["twin", "commit", runID, "--message", String(repeating: "x", count: 4097)], ["twin", "run", runID]
        ]
        for arguments in cases {
            XCTAssertThrowsError(try TwinBridgeCLI.execute(arguments, environment: environment, readInput: { XCTFail("Input read before validation"); return Data() }, call: { _, _ in XCTFail("Invalid arguments reached API"); return try self.response() }, write: { _ in XCTFail("Unexpected output") }))
        }
    }
    func testInvalidSocketsAndMissingRoundFailClosedWithoutGlobalFallback() {
        let environments = [[:], ["TRANO_TWIN_ROUND": "bogus"], ["TRANO_TWIN_ROUND": "1", "TRANO_TWIN_API_SOCKET": ""], ["TRANO_TWIN_ROUND": "1", "TRANO_TWIN_API_SOCKET": "relative.sock"], ["TRANO_TWIN_ROUND": "1", "TRANO_TWIN_API_SOCKET": "/bad\0socket"], ["TRANO_TWIN_ROUND": "1", "TRANO_DATA_DIR": "relative-root"]]
        for value in environments {
            XCTAssertThrowsError(try TwinBridgeCLI.execute(["twin", "diff", runID], environment: value, call: { _, _ in XCTFail("Invalid routing reached API"); return try self.response() }, write: { _ in }))
        }
    }
    func testMalformedNonObjectAndOversizedJSONFailBeforeAPI() {
        for command in ["report", "respond", "hook"] {
            for input in [Data(), Data("{bad".utf8), Data("[]".utf8), Data("null".utf8), Data(repeating: 32, count: command == "hook" ? 524_289 : 16_385)] {
                XCTAssertThrowsError(try TwinBridgeCLI.execute(["twin", command, runID], environment: environment, readInput: { input }, call: { _, _ in XCTFail("Invalid payload reached API"); return try self.response() }, write: { _ in }))
            }
        }
    }
    func testAPIErrorAndThrownMutationNeverRetryOrEmitSuccess() {
        var count = 0
        XCTAssertThrowsError(try TwinBridgeCLI.execute(["twin", "commit", runID, "--message", "fix"], environment: environment, call: { _, _ in count += 1; return try self.response(error: "commit state uncertain") }, write: { _ in XCTFail("Error was emitted as success") }, wait: { _ in XCTFail("Unsafe retry") }))
        XCTAssertEqual(count, 1); count = 0
        XCTAssertThrowsError(try TwinBridgeCLI.execute(["twin", "commit", runID, "--message", "fix"], environment: environment, call: { _, _ in count += 1; throw TerminalError.runtime("transport failure") }, write: { _ in XCTFail("Error output") }, wait: { _ in XCTFail("Unsafe retry") }))
        XCTAssertEqual(count, 1)
    }
    func testCommitRetriesOnlyExplicitBusyWithBoundedInjectedClock() throws {
        var time = 1.0, calls = 0, waits: [TimeInterval] = [], output = Data()
        let result = try TwinBridgeCLI.execute(["twin", "commit", runID, "--message", "fix"], environment: environment, call: { _, _ in
            calls += 1; return try self.response(calls <= 2 ? .object(["status": .string("busy"), "retryAfterMs": .number(250)]) : .object(["commit": .string("abc")]))
        }, write: { output.append($0) }, now: { time }, wait: { waits.append($0); time += $0 })
        XCTAssertEqual(result, 0); XCTAssertEqual(calls, 3); XCTAssertEqual(waits, [0.25, 0.25])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output), .object(["commit": .string("abc")]))
    }
    func testCommitBusyTimeoutIsNonzeroAndCannotLoopOnFrozenClock() throws {
        var calls = 0, waited = 0.0, writes = 0
        let code = try TwinBridgeCLI.execute(["twin", "commit", runID, "--message", "fix"], environment: environment, call: { _, _ in
            calls += 1; return try self.response(.object(["status": .string("busy"), "retryAfterMs": .number(250)]))
        }, write: { _ in writes += 1 }, now: { 1 }, wait: { waited += $0 })
        XCTAssertNotEqual(code, 0); XCTAssertLessThanOrEqual(waited, 30); XCTAssertLessThanOrEqual(calls, 121); XCTAssertEqual(writes, 1)
    }
    func testDecisionAdapterInterceptsOnlyScopedEnvironmentAndNeverBootstrapOrGlobalMode() {
        XCTAssertTrue(TwinBridgeCLI.handles(["decision-adapter", "submit"], environment: environment))
        XCTAssertFalse(TwinBridgeCLI.handles(["decision-adapter", "submit"], environment: ["EASYDECISION_SOCKET": "/fixture/global.sock"]))
        XCTAssertFalse(TwinBridgeCLI.handles(["twin", "run"], environment: environment))
    }
    func testScopedDecisionSubmissionUsesExistingRawAdapterAndInjectedPaneBinding() throws {
        let question: JSONValue = .object(["request_id": .string(runID), "question": .string("프로덕션 작업 승인"), "options": .array([])])
        var output = Data(), sent = 0
        let env = environment.merging(["TRANO_SESSION": "own-pane", "TRANO_LAUNCH_ID": "own-generation", "EASYDECISION_SOCKET": "/forbidden/global.sock"]) { _, new in new }
        let code = try TwinBridgeCLI.execute(["decision-adapter", "submit"], environment: env, readInput: { try! JSONEncoder().encode(question) }, call: { _, _ in XCTFail("Raw adapter cannot use generic API"); return try self.response() }, write: { output.append($0) }, decisionCall: { path, request in
            sent += 1; XCTAssertEqual(path, "/fixture/scoped.sock"); XCTAssertEqual(request["type"], .string("submit")); XCTAssertEqual(request["question"], question)
            XCTAssertEqual(request["trano_binding"], .object(["pane_id": .string("own-pane"), "generation": .string("own-generation")]))
            return .object(["ok": .bool(true), "status": .string("pending"), "request_id": .string(self.runID)])
        })
        XCTAssertEqual(code, 0); XCTAssertEqual(sent, 1)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output)["status"], .string("pending"))
    }
    func testScopedDecisionPollAndGateReuseProtocolWithoutReadingStdin() throws {
        for arguments in [["poll", runID], ["gate", "--agent", "codex", "--session-id", "exact-session"]] {
            _ = try TwinBridgeCLI.execute(["decision-adapter"] + arguments, environment: environment, readInput: { XCTFail("Unexpected decision stdin"); return Data() }, write: { _ in }, decisionCall: { path, request in
                XCTAssertEqual(path, "/fixture/scoped.sock"); XCTAssertEqual(request["type"], .string(arguments[0])); return .object(["ok": .bool(true), "status": .string("answered")])
            })
        }
    }
    func testScopedDecisionBridgeRefusesResolveAbandonAndMissingScopeBeforeTransport() {
        for (args, env) in [(["decision-adapter", "resolve", runID], environment), (["decision-adapter", "abandon", runID], environment), (["decision-adapter", "submit"], [:])] {
            XCTAssertThrowsError(try TwinBridgeCLI.execute(args, environment: env, readInput: { XCTFail("Invalid decision input"); return Data() }, write: { _ in }, decisionCall: { _, _ in XCTFail("Forbidden decision route"); return .null }))
        }
    }

}
