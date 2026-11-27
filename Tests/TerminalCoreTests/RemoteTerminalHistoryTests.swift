import Foundation
import XCTest
@testable import TerminalCore

private final class FakeRemoteHistoryTransport: RemoteTerminalHistoryTransport, @unchecked Sendable {
    let lock = NSLock()
    var remote: [TerminalSession] = []
    var requests: [APIRequest] = []
    var listCount = 0
    var onList: (() throws -> Void)?
    var onCall: ((APIRequest) throws -> APIResponse)?
    func sessions(host: RemoteHost) throws -> [TerminalSession] {
        lock.lock(); listCount += 1; let result = remote; lock.unlock()
        try onList?()
        return result
    }
    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse {
        lock.lock(); requests.append(request); lock.unlock()
        if let onCall { return try onCall(request) }
        let pid = request.params["expectedPID"] ?? .number(-1)
        return APIResponse(result: .object(["historyProtocol": .number(1), "id": request.params["id"] ?? .null,
            "pid": pid, "matched": .bool(true), "inputReady": .bool(request.method == "panes.history.cancel")]))
    }
}

final class RemoteTerminalHistoryTests: XCTestCase {
    let localID = "11111111-1111-4111-8111-111111111111"
    let remoteID = "22222222-2222-4222-8222-222222222222"
    private func fixture() throws -> (TerminalRuntime, FakeRemoteHistoryTransport, RemoteHost) {
        let root = URL(fileURLWithPath: "/tmp/trano-rhist-" + String(UUID().uuidString.prefix(8)))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let host = try RemoteHost(name: "Fixture", address: "fixture.invalid")
        var local = TerminalSession(id: localID, title: "Local bridge", cwd: "/tmp", pid: 12345)
        local.remote = RemoteReference(hostID: host.id, sessionID: remoteID)
        try runtime.update { $0.remoteHosts = [host]; $0.sessions = [local] }
        let fake = FakeRemoteHistoryTransport()
        fake.remote = [TerminalSession(id: remoteID, title: "Remote", cwd: "/tmp", pid: 42)]
        runtime.terminalHistoryRemoteCoordinator = RemoteTerminalHistoryCoordinator(transport: fake)
        return (runtime, fake, host)
    }
    func target(_ host: RemoteHost, id: String? = nil, pid: Int32 = 12345) -> RemoteTerminalHistoryTarget {
        .init(localID: id ?? localID, localPID: pid,
              reference: .init(hostID: host.id, sessionID: remoteID), host: host)
    }

    // Implements: FR-REMOTE-INPUT-1, FR-REMOTE-INPUT-2
    func testActualRuntimeRoutesRemoteScrollAndCancelUsingPinnedRemotePIDInsteadOfBridgePID() throws {
        let (runtime, fake, _) = try fixture()
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 4)
        XCTAssertTrue(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        XCTAssertEqual(fake.listCount, 1)
        XCTAssertEqual(fake.requests.map(\.method), ["panes.history.scroll", "panes.history.cancel"])
        XCTAssertTrue(fake.requests.allSatisfy { $0.params["id"] == .string(remoteID) && $0.params["expectedPID"] == .number(42) })
        XCTAssertEqual(fake.requests.first?.params["lines"], .number(4))
    }
    // Implements: FR-REMOTE-INPUT-1, FR-REMOTE-INPUT-2
    func testRepeatedScrollAndCancelNeverAdoptReplacementRemoteProcess() throws {
        let (runtime, fake, _) = try fixture()
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 3)
        fake.remote[0].pid = 99
        fake.onCall = { request in APIResponse(result: .object(["historyProtocol": .number(1), "id": .string(self.remoteID), "pid": .number(99), "matched": .bool(false), "inputReady": .bool(false)])) }
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 2)
        XCTAssertFalse(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        XCTAssertEqual(fake.listCount, 1)
        XCTAssertTrue(fake.requests.allSatisfy { $0.params["expectedPID"] == .number(42) })
    }
    // Implements: FR-REMOTE-INPUT-1, FR-REMOTE-INPUT-2
    func testInvalidAndStaleLocalIdentityNeverCallsTransport() throws {
        let (runtime, fake, _) = try fixture()
        try runtime.scrollTerminalHistory(localID, expectedPID: 77, lines: 2)
        XCTAssertFalse(try runtime.cancelTerminalHistory(localID, expectedPID: 77))
        XCTAssertThrowsError(try runtime.scrollTerminalHistory("bad", expectedPID: 12345, lines: 1))
        XCTAssertThrowsError(try runtime.scrollTerminalHistory(localID, expectedPID: 0, lines: 1))
        XCTAssertThrowsError(try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 1001))
        XCTAssertEqual(fake.listCount, 0); XCTAssertTrue(fake.requests.isEmpty)
    }
    // Implements: FR-REMOTE-INPUT-2
    func testCancelWithoutPinnedHistoryCannotAuthorizeInputOrQueryReplacement() throws {
        let (runtime, fake, _) = try fixture()
        XCTAssertFalse(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        XCTAssertEqual(fake.listCount, 0); XCTAssertTrue(fake.requests.isEmpty)
    }
    // Implements: FR-REMOTE-INPUT-2, FR-REMOTE-INPUT-3
    func testPostNetworkBridgeReferenceOrHostChangeCannotAuthorizeInput() throws {
        for mutation in 0..<3 {
            let (runtime, fake, _) = try fixture()
            try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 2)
            fake.onCall = { request in
                try runtime.update { state in
                    switch mutation {
                    case 0: state.sessions[0].pid += 1
                    case 1: state.sessions[0].remote = nil
                    default: state.remoteHosts[0].address = "changed.invalid"
                    }
                }
                return APIResponse(result: .object(["historyProtocol": .number(1), "id": .string(self.remoteID), "pid": .number(42), "matched": .bool(true), "inputReady": .bool(true)]))
            }
            XCTAssertFalse(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        }
    }
    // Implements: FR-REMOTE-INPUT-3
    func testNetworkIsOutsideLocalSharedTransactionWhileBlocked() throws {
        let (runtime, fake, _) = try fixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        fake.onList = { entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
        let work = expectation(description: "history finished")
        DispatchQueue.global().async {
            defer { work.fulfill() }
            do { try runtime.scrollTerminalHistory(self.localID, expectedPID: 12345, lines: 1) }
            catch { XCTFail(String(describing: error)) }
        }
        guard entered.wait(timeout: .now() + 2) == .success else { release.signal(); _ = XCTWaiter.wait(for: [work], timeout: 1); XCTFail("Remote transport never entered"); return }
        let changed = expectation(description: "unrelated local mutation")
        DispatchQueue.global().async { defer { changed.fulfill() }; do { try runtime.update { $0.settings.fontSize += 1 } } catch { XCTFail(String(describing: error)) } }
        let result = XCTWaiter.wait(for: [changed], timeout: 1)
        release.signal()
        XCTAssertEqual(result, .completed, "SSH must not retain the local runtime transaction")
        wait(for: [work], timeout: 3)
    }
    // Implements: FR-REMOTE-INPUT-3
    func testReferenceChangeAfterDiscoveryPreventsAnyHistoryRPC() throws {
        let (runtime, fake, _) = try fixture()
        fake.onList = { try runtime.update { $0.sessions[0].pid += 1 } }
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 3)
        XCTAssertEqual(fake.listCount, 1); XCTAssertTrue(fake.requests.isEmpty)
    }
    // Implements: FR-REMOTE-INPUT-2, FR-REMOTE-INPUT-3
    func testMalformedAcknowledgmentsNeverAuthorizeInput() throws {
        let host = try RemoteHost(name: "Fixture", address: "fixture.invalid")
        let variants: [[String: JSONValue]] = [
            ["historyProtocol": .number(2), "id": .string(remoteID), "pid": .number(42), "matched": .bool(true), "inputReady": .bool(true)],
            ["historyProtocol": .number(1), "id": .string(localID), "pid": .number(42), "matched": .bool(true), "inputReady": .bool(true)],
            ["historyProtocol": .number(1), "id": .string(remoteID), "pid": .number(99), "matched": .bool(true), "inputReady": .bool(true)],
            ["historyProtocol": .number(1), "id": .string(remoteID), "pid": .number(42), "matched": .bool(false), "inputReady": .bool(true)],
            ["historyProtocol": .number(1), "id": .string(remoteID), "pid": .number(42), "matched": .string("true"), "inputReady": .bool(true)], [:]
        ]
        for variant in variants {
            let fake = FakeRemoteHistoryTransport(); fake.remote = [TerminalSession(id: remoteID, title: "", cwd: "/tmp", pid: 42)]
            let coordinator = RemoteTerminalHistoryCoordinator(transport: fake)
            _ = try coordinator.update(target(host), lines: 1, current: { true })
            fake.onCall = { _ in APIResponse(result: .object(variant)) }
            XCTAssertThrowsError(try coordinator.update(target(host), lines: nil, current: { true }))
        }
    }
    // Implements: FR-REMOTE-INPUT-2, FR-REMOTE-INPUT-3
    func testOldHelperRequiresVisibleUpdateErrorAndKeepsInputUnsent() throws {
        let (runtime, fake, _) = try fixture()
        fake.onCall = { _ in APIResponse(error: "unknown API method") }
        XCTAssertThrowsError(try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 2)) { error in
            XCTAssertTrue(String(describing: error).lowercased().contains("update trano-server"))
        }
        XCTAssertThrowsError(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        XCTAssertTrue(fake.requests.allSatisfy { $0.method.hasPrefix("panes.history.") })
    }
    // Implements: FR-REMOTE-INPUT-1
    func testDiscoveryRejectsDeadDuplicateOrNonpositiveRemoteIdentity() throws {
        for mutation in 0..<3 {
            let (runtime, fake, _) = try fixture()
            switch mutation {
            case 0: fake.remote[0].alive = false
            case 1: fake.remote.append(fake.remote[0])
            default: fake.remote[0].pid = 0
            }
            XCTAssertThrowsError(try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 1))
            XCTAssertTrue(fake.requests.isEmpty)
        }
    }
    // Implements: FR-REMOTE-INPUT-1, FR-REMOTE-INPUT-3
    func testSuccessfulCancelEndsBindingAndNextExplicitScrollMayPinNewProcess() throws {
        let (runtime, fake, _) = try fixture()
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 2)
        XCTAssertTrue(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        fake.remote[0].pid = 99
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 2)
        XCTAssertEqual(fake.listCount, 2)
        XCTAssertEqual(fake.requests.last?.params["expectedPID"], .number(99))
    }
    // Implements: FR-REMOTE-INPUT-2
    func testRemoteNonInputModeKeepsCancellationFalse() throws {
        let (runtime, fake, _) = try fixture()
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 2)
        fake.onCall = { _ in APIResponse(result: .object(["historyProtocol": .number(1), "id": .string(self.remoteID), "pid": .number(42), "matched": .bool(true), "inputReady": .bool(false)])) }
        XCTAssertFalse(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
    }
    // Implements: FR-REMOTE-INPUT-1, FR-REMOTE-INPUT-3
    func testPinnedTargetSerializesCancelBehindTheInFlightWheelWithoutBlockingLocalState() throws {
        let (runtime, fake, _) = try fixture()
        let scrollEntered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0), cancelEntered = DispatchSemaphore(value: 0)
        fake.onCall = { request in
            if request.method == "panes.history.scroll" {
                scrollEntered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            } else { cancelEntered.signal() }
            return APIResponse(result: .object(["historyProtocol": .number(1), "id": .string(self.remoteID),
                "pid": .number(42), "matched": .bool(true), "inputReady": .bool(request.method == "panes.history.cancel")]))
        }
        let scrollDone = expectation(description: "wheel finished"), cancelDone = expectation(description: "cancel finished")
        DispatchQueue.global().async { defer { scrollDone.fulfill() }; do { try runtime.scrollTerminalHistory(self.localID, expectedPID: 12345, lines: 2) } catch { XCTFail(String(describing: error)) } }
        guard scrollEntered.wait(timeout: .now() + 2) == .success else { release.signal(); _ = XCTWaiter.wait(for: [scrollDone], timeout: 1); XCTFail("No scroll RPC"); return }
        DispatchQueue.global().async { defer { cancelDone.fulfill() }; cancelStarted.signal(); do { let ready = try runtime.cancelTerminalHistory(self.localID, expectedPID: 12345); XCTAssertTrue(ready) } catch { XCTFail(String(describing: error)) } }
        XCTAssertEqual(cancelStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancelEntered.wait(timeout: .now() + 0.1), .timedOut)
        try runtime.update { $0.settings.fontSize += 1 }
        release.signal()
        wait(for: [scrollDone, cancelDone], timeout: 3)
        XCTAssertEqual(fake.requests.map(\.method), ["panes.history.scroll", "panes.history.cancel"])
    }
    // Implements: FR-REMOTE-INPUT-1
    func testBoundedBindingsRetainExistingPIDAndReleaseCapacityAfterExplicitCancel() throws {
        let host = try RemoteHost(name: "Fixture", address: "fixture.invalid")
        let fake = FakeRemoteHistoryTransport()
        fake.remote = [TerminalSession(id: remoteID, title: "", cwd: "/tmp", pid: 42)]
        let coordinator = RemoteTerminalHistoryCoordinator(transport: fake, capacity: 1)
        XCTAssertTrue(try coordinator.update(target(host), lines: 1, current: { true }))
        let another = target(host, id: "33333333-3333-4333-8333-333333333333")
        XCTAssertThrowsError(try coordinator.update(another, lines: 1, current: { true }))
        XCTAssertTrue(try coordinator.update(target(host), lines: nil, current: { true }))
        XCTAssertTrue(try coordinator.update(another, lines: 1, current: { true }))
    }
    // Implements: FR-REMOTE-INPUT-2
    func testZeroLineNoOpStillRejectsInvalidTargetIdentity() throws {
        let (runtime, fake, _) = try fixture()
        XCTAssertThrowsError(try runtime.scrollTerminalHistory("bad", expectedPID: 12345, lines: 0))
        XCTAssertThrowsError(try runtime.scrollTerminalHistory(localID, expectedPID: 0, lines: 0))
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 0)
        XCTAssertEqual(fake.listCount, 0)
    }

    // Implements: FR-REMOTE-INPUT-2
    func testWireJSONMatchesGoContractAndRejectsAnotherAPIVersion() throws {
        let (runtime, fake, _) = try fixture()
        let ready = #"{"apiVersion":1,"result":{"historyProtocol":1,"id":"22222222-2222-4222-8222-222222222222","pid":42,"matched":true,"inputReady":true}}"#
        fake.onCall = { request in
            let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            XCTAssertTrue(wire.contains(#""expectedPID":42"#))
            XCTAssertTrue(wire.contains(#""id":"22222222-2222-4222-8222-222222222222"#))
            return try JSONDecoder().decode(APIResponse.self, from: Data(ready.utf8))
        }
        try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 1)
        XCTAssertTrue(try runtime.cancelTerminalHistory(localID, expectedPID: 12345))
        fake.onCall = { _ in try JSONDecoder().decode(APIResponse.self, from: Data(ready.replacingOccurrences(of: #""apiVersion":1"#, with: #""apiVersion":2"#).utf8)) }
        XCTAssertThrowsError(try runtime.scrollTerminalHistory(localID, expectedPID: 12345, lines: 1))
    }

}
