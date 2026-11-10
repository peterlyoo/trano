import XCTest
@testable import TerminalCore

final class APITests: XCTestCase {
    // Implements: U16
    func testServiceResponseCallbackRunsAfterAnAcknowledgedRequest() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-ack-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let callback = expectation(description: "Acknowledged response")
        let service = APIService(runtime: runtime, responseDidSend: { request, response in
            if request.method == "server.info", response.error == nil { callback.fulfill() }
        })
        defer { service.stop(); try? FileManager.default.removeItem(at: root) }
        try service.start()
        let response = try APIClient(path: service.path).call(APIRequest(method: "server.info"))
        XCTAssertEqual(response.result?["pid"], .number(Double(getpid())))
        XCTAssertNotNil(response.result?["buildID"]?.text)
        wait(for: [callback], timeout: 2)
    }

    // Implements: FR-CORE-2, NFR-CORE-2
    func testAPILeaseSurvivesRejectedDuplicateAndImmediateRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-lease-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let first = APIService(runtime: runtime), second = APIService(runtime: runtime)
        defer { first.stop(); second.stop(); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<5 {
            try first.start()
            XCTAssertThrowsError(try second.start())
            XCTAssertNil(try APIClient(path: first.path).call(APIRequest(method: "server.info")).error)
            first.stop()
            try second.start()
            XCTAssertNil(try APIClient(path: second.path).call(APIRequest(method: "server.info")).error)
            second.stop()
        }
    }
    // Implements: FR-CORE-2, FR-CORE-7, NFR-CORE-2
    func testUnixAPIRejectsInvalidVersionAndPreservesExplicitState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("at-api-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let service = APIService(runtime: runtime)
        try service.start()
        defer {
            service.stop()
            for item in (try? runtime.list()) ?? [] { try? runtime.terminate(item.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let client = APIClient(path: service.path)
        let info = try client.call(APIRequest(method: "server.info"))
        XCTAssertNil(info.error)
        XCTAssertEqual(info.result?["apiVersion"], .number(1))
        let created = try client.call(APIRequest(method: "sessions.create", params: ["title": .string("API terminal"), "cwd": .string(root.path)]))
        guard case .string(let id)? = created.result?["id"] else { return XCTFail("Missing created session ID") }
        let reported = try client.call(APIRequest(method: "activity.report", params: ["id": .string(id), "state": .string("blocked"), "reason": .string("permission"), "agent": .string("codex")]))
        XCTAssertNil(reported.error)
        XCTAssertEqual(try runtime.list().first?.activity.state, .blocked)
        let invalid = try client.call(APIRequest(apiVersion: 99, method: "server.info"))
        XCTAssertNotNil(invalid.error)
        let unknown = try client.call(APIRequest(method: "sessions.terminate", params: ["id": .string("not-an-id")]))
        XCTAssertNotNil(unknown.error)
        XCTAssertEqual(try runtime.list().count, 1)
        XCTAssertThrowsError(try APIService(runtime: runtime).start())
    }
}
