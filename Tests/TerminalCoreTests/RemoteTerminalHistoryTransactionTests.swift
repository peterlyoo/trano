import Foundation
import XCTest
@testable import TerminalCore

private final class TransactionHistoryTransport: RemoteTerminalHistoryTransport {
    let remoteID = "22222222-2222-4222-8222-222222222222"
    var discoveries = 0
    var calls = 0
    func sessions(host: RemoteHost) throws -> [TerminalSession] {
        discoveries += 1
        return [TerminalSession(id: remoteID, title: "Fixture", cwd: "/tmp", pid: 42)]
    }
    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse {
        calls += 1
        return APIResponse(result: .object(["historyProtocol": .number(1), "id": .string(remoteID), "pid": .number(42),
            "matched": .bool(true), "inputReady": .bool(request.method == "panes.history.cancel")]))
    }
}

final class RemoteTerminalHistoryTransactionTests: XCTestCase {
    private let localID = "11111111-1111-4111-8111-111111111111"
    private func fixture() throws -> (TerminalRuntime, TransactionHistoryTransport) {
        let root = URL(fileURLWithPath: "/tmp/trano-rhtx-" + String(UUID().uuidString.prefix(8)))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let transport = TransactionHistoryTransport()
        let host = try RemoteHost(name: "Fixture", address: "fixture.invalid")
        var session = TerminalSession(id: localID, title: "Bridge", cwd: "/tmp", pid: 12345)
        session.remote = RemoteReference(hostID: host.id, sessionID: transport.remoteID)
        try runtime.update { $0.remoteHosts = [host]; $0.sessions = [session] }
        runtime.terminalHistoryRemoteCoordinator = RemoteTerminalHistoryCoordinator(transport: transport)
        return (runtime, transport)
    }

    // Implements: FR-REMOTE-INPUT-3
    func testOuterTransactionRejectsRemoteScrollBeforeDiscoveryOrRPC() throws {
        let (runtime, transport) = try fixture()
        XCTAssertThrowsError(try runtime.transaction {
            try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 3)
        }) { error in
            XCTAssertTrue(String(describing: error).contains("outside the shared runtime transaction"))
        }
        XCTAssertEqual(transport.discoveries, 0)
        XCTAssertEqual(transport.calls, 0)
    }

    // Implements: FR-REMOTE-INPUT-3
    func testOuterTransactionRejectsPinnedRemoteCancelBeforeRPCAndKeepsExplicitRetrySafe() throws {
        let (runtime, transport) = try fixture()
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 3)
        XCTAssertEqual(transport.discoveries, 1)
        XCTAssertEqual(transport.calls, 1)
        transport.discoveries = 0; transport.calls = 0
        XCTAssertThrowsError(try runtime.transaction {
            try runtime.cancelTerminalHistory(localID, expectedPID: 12345)
        }) { error in
            XCTAssertTrue(String(describing: error).contains("outside the shared runtime transaction"))
        }
        XCTAssertEqual(transport.discoveries, 0)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertTrue(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        XCTAssertEqual(transport.discoveries, 0, "A refused call must retain the pinned PID for explicit retry")
        XCTAssertEqual(transport.calls, 1)
    }
}
