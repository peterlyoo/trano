import Foundation
import XCTest
@testable import TerminalCore

final class ClosedRemoteTerminalTests: XCTestCase {
    private final class Transport: ClosedRemoteTerminalTransport {
        var requests: [APIRequest] = []
        var reply: (APIRequest) throws -> APIResponse
        init(_ reply: @escaping (APIRequest) throws -> APIResponse) { self.reply = reply }
        func call(host: RemoteHost, request: APIRequest) throws -> APIResponse {
            requests.append(request)
            return try reply(request)
        }
    }

    private let remoteID = "31a856b4-2222-4222-8222-222222222222"
    private let operationID = "42a856b4-2222-4222-8222-222222222222"

    private func fixture() throws -> (RemoteHost, TerminalSession) {
        let host = try RemoteHost(name: "Fixture", address: "fixture.invalid")
        var pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/fixture", pid: 100)
        pane.remote = RemoteReference(hostID: host.id, sessionID: remoteID)
        return (host, pane)
    }

    private func token(_ phase: String) -> RemoteClosedTerminal {
        RemoteClosedTerminal(closeProtocol: 1, operationID: operationID, sessionID: remoteID,
            expectedPID: 42, generation: "42:700:123:42", phase: phase, historyProvenance: "persistedFallback")
    }

    private func response(_ value: some Encodable) throws -> APIResponse {
        APIResponse(result: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)))
    }

    // Implements: FR-CLOSE-6
    func testLegacyHelperIsRejectedBeforeSessionMutation() throws {
        let (host, pane) = try fixture()
        let transport = Transport { _ in APIResponse(result: .object(["apiVersion": .number(1)])) }
        let adapter = ClosedRemoteTerminalAdapter(host: host, transport: transport)
        XCTAssertThrowsError(try adapter.prepare(pane: pane, operationID: operationID))
        XCTAssertEqual(transport.requests.map(\.method), ["server.info"])
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-6
    func testPrepareFreezesDiscoveredRemoteGeneration() throws {
        let (host, pane) = try fixture()
        var remote = TerminalSession(id: remoteID, title: "Remote", cwd: "/fixture", pid: 42)
        remote.inputBackendIdentity = "42:700:123:42"
        let transport = Transport { request in
            switch request.method {
            case "server.info": return APIResponse(result: .object(["closedTerminalProtocol": .number(1)]))
            case "sessions.list": return try self.response([remote])
            case "close.prepare": return try self.response(self.token("prepared"))
            default: throw TerminalError.runtime("Unexpected fixture request")
            }
        }
        let result = try ClosedRemoteTerminalAdapter(host: host, transport: transport).prepare(pane: pane, operationID: operationID)
        XCTAssertEqual(result, token("prepared"))
        XCTAssertEqual(transport.requests.last?.params["expectedPID"], .number(42))
        XCTAssertEqual(transport.requests.last?.params["expectedGeneration"], .string("42:700:123:42"))
        XCTAssertEqual(transport.requests.map(\.method), ["server.info", "sessions.list", "close.prepare"])
    }

    // Implements: FR-CLOSE-2, FR-CLOSE-6
    func testLostCommitResponseReconcilesStatusWithoutSecondKill() throws {
        let (host, pane) = try fixture()
        let transport = Transport { request in
            switch request.method {
            case "server.info": return APIResponse(result: .object(["closedTerminalProtocol": .number(1)]))
            case "close.commit": throw TerminalError.runtime("Fixture connection ended")
            case "close.status": return try self.response(self.token("closed"))
            default: throw TerminalError.runtime("Unexpected fixture request")
            }
        }
        let result = try ClosedRemoteTerminalAdapter(host: host, transport: transport).commit(pane: pane, snapshot: token("prepared"))
        XCTAssertEqual(result.phase, "closed")
        XCTAssertEqual(transport.requests.map(\.method), ["server.info", "close.commit", "close.status"])
    }

    // Implements: FR-CLOSE-3, FR-CLOSE-6
    func testLostReopenResponseUsesAcknowledgedFreshSession() throws {
        let (host, pane) = try fixture()
        let remote = TerminalSession(id: remoteID, title: "Remote", cwd: "/fixture", pid: 84)
        let transport = Transport { request in
            switch request.method {
            case "server.info": return APIResponse(result: .object(["closedTerminalProtocol": .number(1)]))
            case "close.reopen": throw TerminalError.runtime("Fixture connection ended")
            case "close.status":
                guard let encoded = try self.response(self.token("reopened")).result,
                      case .object(var body) = encoded else { throw TerminalError.runtime("Fixture encode failure") }
                body["session"] = try self.response(remote).result
                return APIResponse(result: .object(body))
            default: throw TerminalError.runtime("Unexpected fixture request")
            }
        }
        let result = try ClosedRemoteTerminalAdapter(host: host, transport: transport).reopen(pane: pane, snapshot: token("closed"))
        XCTAssertEqual(result.pid, 84)
        XCTAssertEqual(transport.requests.map(\.method), ["server.info", "close.reopen", "close.status"])
    }

    // Implements: FR-CLOSE-6
    func testMismatchedOperationAndUncertainCloseNeverBecomeSuccess() throws {
        let (host, pane) = try fixture()
        let transport = Transport { request in
            if request.method == "server.info" { return APIResponse(result: .object(["closedTerminalProtocol": .number(1)])) }
            return try self.response(self.token("committing"))
        }
        XCTAssertThrowsError(try ClosedRemoteTerminalAdapter(host: host, transport: transport).commit(pane: pane, snapshot: token("prepared")))
        var wrong = token("closed")
        wrong.operationID = UUID().uuidString.lowercased()
        let mismatched = Transport { request in
            if request.method == "server.info" { return APIResponse(result: .object(["closedTerminalProtocol": .number(1)])) }
            return try self.response(wrong)
        }
        XCTAssertThrowsError(try ClosedRemoteTerminalAdapter(host: host, transport: mismatched).status(pane: pane, operationID: operationID))
    }

    // Implements: FR-CLOSE-1, FR-CLOSE-2, FR-CLOSE-6
    func testCancellationAndCommitRequireExactAcknowledgments() throws {
        let (host, pane) = try fixture()
        let cancellation = Transport { request in
            if request.method == "server.info" { return APIResponse(result: .object(["closedTerminalProtocol": .number(1)])) }
            return try self.response(self.token("cancelled"))
        }
        try ClosedRemoteTerminalAdapter(host: host, transport: cancellation).cancel(pane: pane, snapshot: token("prepared"))
        XCTAssertEqual(cancellation.requests.map(\.method), ["server.info", "close.cancel"])
        XCTAssertEqual(cancellation.requests.last?.params["expectedGeneration"], .string(token("prepared").generation))
        for phase in ["reopening", "reopened"] {
            let transport = Transport { request in
                if request.method == "server.info" { return APIResponse(result: .object(["closedTerminalProtocol": .number(1)])) }
                return try self.response(self.token(phase))
            }
            XCTAssertThrowsError(try ClosedRemoteTerminalAdapter(host: host, transport: transport).commit(pane: pane, snapshot: token("prepared")))
        }
    }
}
