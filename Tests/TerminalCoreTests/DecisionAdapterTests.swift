import XCTest
import Darwin
@testable import TerminalCore

final class DecisionAdapterTests: XCTestCase {
    // Implements: FR-DECISION-1
    func testOlderServiceEnvelopeRequestsNativeFallbackDuringAppHandoff() throws {
        var output = Data()
        let code = DecisionAdapterCommand.run(arguments: ["poll", UUID().uuidString.lowercased()], socketPath: "/fixture/socket",
            input: { Data() }, output: { output.append($0) }, transport: { _ in
                .object(["apiVersion": .number(1), "error": .string("Unknown method")])
            })
        XCTAssertEqual(code, 75)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output)["error"], .string("NATIVE_FALLBACK_REQUIRED"))
    }

    // Implements: FR-DECISION-1
    func testManagedEnvironmentUsesOwnedShimWithoutChangingGlobalAdapter() throws {
        let root = URL(fileURLWithPath: "/tmp/tde-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root, helperExecutable: "/fixture/trano")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ["PATH": "/usr/bin:/bin", "EASYDECISION_SOCKET": "/fixture/global.sock", "EASYDECISION_ADAPTER_BIN": "/fixture/global-adapter"]
        let managed = try runtime.decisionEnvironment(original)
        XCTAssertEqual(managed["EASYDECISION_SOCKET"], root.path + "/api.sock")
        XCTAssertEqual(managed["EASYDECISION_ADAPTER_BIN"], root.path + "/shell/bin/easydecision-adapter")
        XCTAssertEqual(managed["PATH"], root.path + "/shell/bin:/usr/bin:/bin")
        XCTAssertEqual(original["EASYDECISION_SOCKET"], "/fixture/global.sock")
        XCTAssertEqual(try runtime.decisionEnvironment(managed), managed)
        let shim = try XCTUnwrap(managed["EASYDECISION_ADAPTER_BIN"])
        XCTAssertTrue(try String(contentsOfFile: shim).contains("decision-adapter"))
        let attrs = try FileManager.default.attributesOfItem(atPath: shim)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    // Implements: FR-DECISION-1
    func testBuiltInAdapterPollsWithoutRetainingAProcessOrReplacingPendingWithFallback() throws {
        let id = UUID().uuidString.lowercased()
        var operations: [String] = [], outputs: [Data] = []
        var now = Date(timeIntervalSince1970: 0)
        let code = DecisionAdapterCommand.run(arguments: ["poll", id, "--wait-ms", "50", "--interval-ms", "25"], socketPath: "/tmp/isolated.sock",
            input: { XCTFail("poll must not read stdin"); return Data() }, output: { outputs.append($0) },
            transport: { request in
                operations.append(request["type"]!.text!)
                return .object(["ok": .bool(true), "request_id": .string(id), "status": .string("pending")])
            }, sleep: { now.addTimeInterval($0) }, now: { now })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(operations, ["poll", "poll", "poll"])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: outputs[0])["status"], .string("pending"))
    }

    // Implements: FR-DECISION-1
    func testAdapterUnavailableAndUnsupportedCommandsHaveDifferentExitCodes() throws {
        var output: [Data] = []
        let id = UUID().uuidString.lowercased()
        let unavailable = DecisionAdapterCommand.run(arguments: ["poll", id], socketPath: "/tmp/none.sock", input: { Data() }, output: { output.append($0) },
            transport: { _ in throw TerminalError.runtime("fixture unavailable") })
        XCTAssertEqual(unavailable, 75)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output[0])["error"], .string("NATIVE_FALLBACK_REQUIRED"))
        output = []
        XCTAssertEqual(DecisionAdapterCommand.run(arguments: ["context"], socketPath: "/tmp/none.sock", input: { Data() }, output: { output.append($0) }), 2)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: output[0])["error"], .string("UNSUPPORTED_FEATURE"))
    }

    // Implements: FR-DECISION-1
    func testActualShortLivedRawAdapterClientSharesAPIEndpoint() throws {
        let root = URL(fileURLWithPath: "/tmp/tds-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root), service = APIService(runtime: runtime)
        defer { service.stop(); try? FileManager.default.removeItem(at: root) }
        let paneID = UUID().uuidString.lowercased(), sessionID = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: paneID, title: "Fixture", cwd: root.path, pid: 0)) }
        let launch = try runtime.beginAgentLaunch(paneID: paneID, provider: .codex, cwd: root.path)
        try runtime.update { $0.agentLaunches[0].providerSessionID = sessionID; $0.agentLaunches[0].providerPID = getpid() }
        try service.start()
        let client = DecisionAdapterClient(path: service.path)
        let response = try client.call(.object(["type": .string("poll"), "request_id": .string(UUID().uuidString.lowercased())]))
        XCTAssertEqual(response["ok"], .bool(false))
        XCTAssertEqual(response["error"], .string("UNKNOWN_REQUEST"))
        let requestID = UUID().uuidString.lowercased(), threadID = UUID().uuidString.lowercased()
        let question: JSONValue = .object([
            "schema_version": .string("1.0"), "request_id": .string(requestID), "thread_id": .string(threadID),
            "source": .object(["agent": .string("codex"), "session_id": .string(sessionID), "workspace": .string(root.path)]),
            "question": .string("Use persistent storage?"), "options": .array([
                .object(["id": .string("disk"), "label": .string("Disk"), "description": .string("Survives restart.")]),
                .object(["id": .string("memory"), "label": .string("Memory"), "description": .string("Clears on exit.")])])])
        XCTAssertEqual(try client.call(.object(["type": .string("submit"), "question": question]))["status"], .string("pending"))
        XCTAssertEqual(try runtime.decisionInbox(paneID: paneID).count, 1)
        _ = try runtime.resolveDecision(requestID, generation: launch.id, action: "choose", optionID: "disk")
        let answer = try client.call(.object(["type": .string("poll"), "request_id": .string(requestID)]))
        XCTAssertEqual(answer["status"], .string("resolved"))
        XCTAssertEqual(answer["response"]?["thread_id"], .string(threadID))
        XCTAssertEqual(answer["response"]?["selected_option_id"], .string("disk"))
        XCTAssertEqual(try client.call(.object(["type": .string("abandon"), "request_id": .string(requestID)])), answer)
        XCTAssertNil(try APIClient(path: service.path).call(APIRequest(method: "server.info")).error)
    }
}
