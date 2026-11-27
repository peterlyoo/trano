import Foundation
import XCTest
@testable import TerminalCore

final class ServerStatusTests: XCTestCase {
    // Implements: FR-SERVER-2, FR-SERVER-4, FR-SERVER-5
    func testRunningRequiresMatchingResponseAndRecordsFreshness() throws {
        var state = ServerStatusState(pid: 42, buildID: "build")
        state.setItemRegistered(true)
        let lease = try XCTUnwrap(state.beginProbe())
        XCTAssertNil(state.beginProbe())
        state.finishProbe(lease, result: .success(try identity()), now: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(state.snapshot.phase, .running)
        XCTAssertEqual(state.snapshot.verifiedAt, Date(timeIntervalSince1970: 50))
        XCTAssertTrue(state.snapshot.itemRegistered)
        XCTAssertEqual(state.snapshot.title, "Trano Server Running")
        XCTAssertNil(state.snapshot.error)
    }

    func testAllIdentityFieldsAndErrorsFailClosed() throws {
        for patch: [String: JSONValue] in [["pid": .number(99)], ["buildID": .string("old")], ["serviceKind": .string("cli")], ["apiVersion": .number(2)]] {
            XCTAssertThrowsError(try ServerHealthIdentity.validate(identity(patch), pid: 42, buildID: "build"))
        }
        XCTAssertThrowsError(try ServerHealthIdentity.validate(APIResponse(error: "unavailable"), pid: 42, buildID: "build"))
        var state = ServerStatusState(pid: 42, buildID: "build")
        let lease = try XCTUnwrap(state.beginProbe())
        state.finishProbe(lease, result: .failure(TerminalError.runtime("connection failed")), now: Date())
        XCTAssertEqual(state.snapshot.phase, .connectionError)
        XCTAssertNil(state.snapshot.verifiedAt)
        XCTAssertNotNil(state.snapshot.error)
        XCTAssertTrue(state.snapshot.canRetry)
    }

    func testRestartRevokesOldProbeAndClearsReadiness() throws {
        var state = ServerStatusState(pid: 42, buildID: "build")
        let old = try XCTUnwrap(state.beginProbe())
        let generation = state.beginStart(restarting: true)
        state.finishProbe(old, result: .success(try identity()), now: Date())
        XCTAssertEqual(state.snapshot.phase, .restarting)
        XCTAssertNil(state.beginProbe())
        state.finishStart(generation, error: nil)
        let current = try XCTUnwrap(state.beginProbe())
        state.finishProbe(current, result: .success(try identity()), now: Date())
        XCTAssertEqual(state.snapshot.phase, .running)
        state.finishStart(generation - 1, error: "old failure")
        XCTAssertEqual(state.snapshot.phase, .running)
    }

    func testStartupFailureAndShutdownRemainExplicit() {
        var state = ServerStatusState(pid: 42, buildID: "build")
        let generation = state.beginStart(restarting: false)
        state.finishStart(generation, error: "tmux missing")
        XCTAssertEqual(state.snapshot.phase, .startupError)
        XCTAssertTrue(state.snapshot.canRetry)
        XCTAssertNil(state.beginProbe())
        state.stop()
        XCTAssertEqual(state.snapshot.phase, .stopped)
        XCTAssertNil(state.snapshot.verifiedAt)
    }

    func testFrameRejectsOversizedAndInvalidReplies() throws {
        var buffer = ServerHealthResponseBuffer()
        XCTAssertNil(try buffer.append(Data("{\"apiVersion\":1,".utf8)))
        let response = try XCTUnwrap(buffer.append(Data("\"result\":{\"apiVersion\":1,\"pid\":42,\"buildID\":\"build\",\"serviceKind\":\"background\"}}\n".utf8)))
        try ServerHealthIdentity.validate(response, pid: 42, buildID: "build")
        var oversized = ServerHealthResponseBuffer()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: 16_385)))
        var invalid = ServerHealthResponseBuffer()
        XCTAssertThrowsError(try invalid.append(Data("oops\n".utf8)))
    }

    func testCachedDiagnosticsAreSerializableWithoutRuntimeReads() throws {
        let cache = ServerStatusCache(ServerStatusState(pid: 42, buildID: "build").snapshot)
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cache.snapshot()))
        XCTAssertEqual(value["phase"], .string("starting"))
        XCTAssertEqual(value["itemRegistered"], .bool(false))
        XCTAssertEqual(value["pid"], .number(42))
    }

    func testHelperLeaseIsIndependentOfUninitializedRuntimeAndExclusive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-status-unit-" + UUID().uuidString)
        var owner: ServerHelperLease? = try ServerHelperLease(root: root)
        XCTAssertNotNil(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try ServerHelperLease(root: root)) { error in
            XCTAssertTrue(error is ServerHelperLeaseError)
        }
        owner = nil
        XCTAssertNoThrow(try ServerHelperLease(root: root))
    }

    func testInvalidatedRemoteCoordinatorCannotBeResurrectedByDelayedRestore() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-status-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = ServerStatusFakeRemoteListener()
        var preferences = ServerPreferences(); preferences.serveOverTailscale = true
        let coordinator = try RemoteServingCoordinator(root: root, listener: listener, preferences: { preferences }, identity: { nil }, route: { _ in APIResponse() })
        let delayedRestore = { try coordinator.restoreIfEnabled() }
        coordinator.invalidate()
        XCTAssertThrowsError(try delayedRestore())
        XCTAssertThrowsError(try coordinator.start())
        XCTAssertEqual(listener.starts, 0)
        XCTAssertNil(coordinator.target)
    }

    func testHealthDeadlineDoesNotResetForSlowTrickleAndBoundsInvalidTimeouts() throws {
        let deadline = ServerHealthDeadline(timeout: 1, now: 10)
        XCTAssertEqual(try deadline.waitMilliseconds(now: 10), 1000)
        XCTAssertLessThanOrEqual(try deadline.waitMilliseconds(now: 10.9), 100)
        XCTAssertThrowsError(try deadline.waitMilliseconds(now: 11))
        XCTAssertThrowsError(try deadline.waitMilliseconds(now: 12))
        XCTAssertEqual(try ServerHealthDeadline(timeout: .infinity, now: 10).waitMilliseconds(now: 10), 1000)
    }

    func testHealthOnlyRouteReturnsCachedStatusWithoutAuxiliaryStateFields() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-health-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let cache = ServerStatusCache(ServerStatusState(pid: getpid(), buildID: "build").snapshot)
        let service = APIService(runtime: runtime, serverStatus: { cache.json() })
        let response = service.route(APIRequest(method: "server.info", params: ["healthOnly": .bool(true)]))
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["serverStatus"]?["phase"], .string("starting"))
        XCTAssertEqual(response.result?["pid"], .number(Double(getpid())))
        XCTAssertNil(response.result?["label"])
        XCTAssertNil(response.result?["remoteReady"])
        XCTAssertNil(response.result?["localAPIURL"])
    }

    private func identity(_ patch: [String: JSONValue] = [:]) throws -> APIResponse {
        var result: [String: JSONValue] = ["apiVersion": .number(1), "pid": .number(42), "buildID": .string("build"), "serviceKind": .string("background")]
        result.merge(patch) { _, new in new }
        return APIResponse(result: .object(result))
    }
}

private final class ServerStatusFakeRemoteListener: RemoteHTTPListening {
    var target: String?
    var starts = 0
    func start(gateway: RemoteHTTPGateway) throws -> String { starts += 1; target = "fake"; return "fake" }
    func stop() { target = nil }
}
