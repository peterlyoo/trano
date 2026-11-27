import Foundation
import XCTest
@testable import TerminalCore

final class ServerRemoteRuntimeTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-http-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func mockCLI(in root: URL, content: String) throws -> URL {
        let path = root.appendingPathComponent("tailscale")
        try TerminalRuntime.atomicWrite(Data(("#!/bin/sh\n" + content + "\n").utf8), to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    // Implements: FR-SET-22, FR-SET-27
    func testOptionalExecutorUsesExactArgumentsAndReportsBoundedOutputAndExitCode() throws {
        let root = try root(), executable = try mockCLI(in: root, content: "printf '%s' \"$1\"\nexit 7")
        let executor = BoundedTailscaleExecutor(executable: executable)
        let result = try executor.run(arguments: ["literal; no shell expansion"])
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "literal; no shell expansion")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(BoundedTailscaleExecutor.installedExecutable(path: root.path)?.path, executable.path)
    }
    // Implements: FR-SET-27
    func testExecutorTimesOutAndRejectsOutputFloodWithoutRealTailscale() throws {
        let root = try root(), sleeper = try mockCLI(in: root, content: "exec /bin/sleep 10")
        let before = Date()
        XCTAssertThrowsError(try BoundedTailscaleExecutor(executable: sleeper, timeout: 0.1).run(arguments: []))
        XCTAssertLessThan(Date().timeIntervalSince(before), 2)
        let flood = try mockCLI(in: root, content: "printf 'abcdefghijklmnopqrstuvwxyz'")
        XCTAssertThrowsError(try BoundedTailscaleExecutor(executable: flood, maximumOutputBytes: 8).run(arguments: []))
    }
    // Implements: FR-SET-21, FR-SET-22, FR-SET-24, FR-SET-29
    func testCoordinatorRestoresOnlyOptedInListenerAndRefreshesIdentityForGateway() throws {
        let listener = FakeRemoteListener(), root = try root()
        var preferences = ServerPreferences()
        var identity = try TailscaleSnapshot(data: Data(#"{"BackendState":"Running","Self":{"UserID":1},"User":{"1":{"LoginName":"me@test"}}}"#.utf8))
        let coordinator = try RemoteServingCoordinator(root: root, listener: listener, preferences: { preferences }, identity: { identity }, route: { _ in APIResponse(result: .bool(true)) })
        try coordinator.restoreIfEnabled(); XCTAssertEqual(listener.starts, 0)
        preferences.serveOverTailscale = true
        try coordinator.restoreIfEnabled(); XCTAssertEqual(coordinator.target, "unix:/tmp/fake/r.sock"); XCTAssertEqual(listener.starts, 1)
        XCTAssertEqual(try coordinator.start(), "unix:/tmp/fake/r.sock"); XCTAssertEqual(listener.starts, 1)
        let invitation = try coordinator.pairing.invite()
        let credential = try coordinator.pairing.pair(code: invitation.code, label: "Client", login: "me@test", ownLogin: "me@test", preferences: preferences)
        let body = try JSONEncoder().encode(APIRequest(method: "server.info"))
        let request = RemoteHTTPRequest(method: "POST", path: "/api", headers: ["authorization": "Bearer " + credential.token, "content-type": "application/json", "tailscale-user-login": "me@test"], body: body)
        XCTAssertEqual(try XCTUnwrap(listener.gateway).respond(request, proxy: TrustedTailscaleProxy()).status, 200)
        identity = try TailscaleSnapshot(data: Data(#"{"BackendState":"Running","Self":{"UserID":2},"User":{"2":{"LoginName":"other@test"}}}"#.utf8))
        coordinator.refreshIdentity()
        XCTAssertEqual(try XCTUnwrap(listener.gateway).respond(request, proxy: TrustedTailscaleProxy()).status, 403)
        coordinator.stop(); XCTAssertNil(coordinator.target); XCTAssertEqual(listener.stops, 1)
    }
    // Implements: FR-SET-19, FR-SET-28, FR-SET-112
    func testActualLocalInfoRoutePublishesLabelUptimeAndUnixEndpoint() throws {
        let runtime = try TerminalRuntime(root: root())
        let sidecar = try SecureSettingsSidecar<ServerPreferences>(root: runtime.root, filename: "server-settings.json")
        let baseline = try sidecar.load(); var edited = baseline; edited.clientLabel = "Desktop"
        _ = try sidecar.merge(baseline: baseline, edited: edited)
        let info = try XCTUnwrap(APIService(runtime: runtime).route(APIRequest(method: "server.info")).result)
        XCTAssertEqual(info["label"], .string("Desktop"))
        XCTAssertEqual(info["localAPIURL"], .string("unix://" + runtime.root.appendingPathComponent("api.sock").path))
        guard case .number(let uptime)? = info["uptime"] else { return XCTFail("Missing actual server uptime") }
        XCTAssertGreaterThanOrEqual(uptime, 0)
    }
}
private final class FakeRemoteListener: RemoteHTTPListening {
    var target: String?
    var starts = 0, stops = 0
    var gateway: RemoteHTTPGateway?
    func start(gateway: RemoteHTTPGateway) throws -> String { starts += 1; self.gateway = gateway; target = "unix:/tmp/fake/r.sock"; return target! }
    func stop() { stops += 1; target = nil; gateway = nil }
}
