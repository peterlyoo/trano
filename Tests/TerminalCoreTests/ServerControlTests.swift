import Foundation
import XCTest
@testable import TerminalCore

final class ServerControlTests: XCTestCase {
    private func root() throws -> URL {
        let path = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-srv-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private var identity: BuildIdentity { BuildIdentity(info: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "a", count: 64)]) }

    // Implements: FR-SET-19, FR-SET-20, FR-SET-28, FR-SET-112
    func testStatusUsesActualHandshakeAndCompatibilityWithoutMutatingServer() throws {
        let info: JSONValue = .object(["apiVersion": .number(1), "version": .string("0.1"), "buildNumber": .string("1"), "buildID": .string(identity.buildID), "pid": .number(100), "uptime": .number(12), "serviceKind": .string("background")])
        let snapshot = ServerRuntimeSnapshot(response: APIResponse(result: info), expected: identity, root: URL(fileURLWithPath: "/tmp/trano"), label: "Desktop")
        XCTAssertTrue(snapshot.running); XCTAssertEqual(snapshot.compatibility, .compatible)
        XCTAssertEqual(snapshot.uptime, 12); XCTAssertEqual(snapshot.pid, 100)
        XCTAssertEqual(snapshot.localAPIURL, "unix:///tmp/trano/api.sock"); XCTAssertEqual(snapshot.label, "Desktop")
        var mismatch = info
        if case .object(var fields) = mismatch { fields["buildID"] = .string(String(repeating: "b", count: 64)); mismatch = .object(fields) }
        XCTAssertEqual(ServerRuntimeSnapshot(response: APIResponse(result: mismatch), expected: identity, root: URL(fileURLWithPath: "/tmp/trano"), label: "Desktop").compatibility, .restartRequired)
        if case .object(var fields) = mismatch { fields["apiVersion"] = .number(9); mismatch = .object(fields) }
        XCTAssertEqual(ServerRuntimeSnapshot(response: APIResponse(result: mismatch), expected: identity, root: URL(fileURLWithPath: "/tmp/trano"), label: "Desktop").compatibility, .unsupported)
        XCTAssertFalse(ServerRuntimeSnapshot(response: nil, expected: identity, root: URL(fileURLWithPath: "/tmp/trano"), label: "Desktop").running)
    }

    // Implements: FR-SET-22, FR-SET-27
    func testTailscaleAbsentToolAndForeignServeOrFunnelAreExplicitlyUnavailable() throws {
        let absent = try TailscaleAdministration(root: root(), executor: nil)
        XCTAssertThrowsError(try absent.refresh()); XCTAssertThrowsError(try absent.enable())
        let tool = FakeTailscale(); tool.replies = [Data(#"{"Web":{"node.test:443":{"Handlers":{"/trano":{"Proxy":"http://127.0.0.1:9999"}}}}}"#.utf8)]
        let admin = try TailscaleAdministration(root: root(), executor: tool)
        XCTAssertThrowsError(try admin.enable()); XCTAssertEqual(tool.commands.count, 1)
        tool.commands = []; tool.replies = [Data(#"{"AllowFunnel":{"node.test:443":true}}"#.utf8)]
        XCTAssertThrowsError(try admin.enable()); XCTAssertEqual(tool.commands.count, 1)
    }

    // Implements: FR-SET-21, FR-SET-22, FR-SET-27
    func testServeRequiresVerifiedReadbackAndDisablesOnlyOwnedHandler() throws {
        let tool = FakeTailscale(), admin = try TailscaleAdministration(root: root(), executor: tool)
        let active = try JSONEncoder().encode(JSONValue.object(["Web": .object(["node.test:443": .object(["Handlers": .object(["/trano": .object(["Proxy": .string(admin.target)])])])])]))
        tool.replies = [Data("{}".utf8), Data("ok".utf8), active]
        try admin.enable()
        XCTAssertEqual(tool.commands, [["serve", "status", "--json"], TailscaleCommand.serve(target: admin.target).arguments, ["serve", "status", "--json"]])
        tool.commands = []; tool.replies = [active, Data("ok".utf8), Data("{}".utf8)]
        try admin.disable()
        XCTAssertEqual(tool.commands[1], TailscaleCommand.stopServing.arguments)
        XCTAssertFalse(tool.commands.joined().contains("reset"))
        tool.commands = []; tool.replies = [Data("{}".utf8), Data("approval needed".utf8), Data("{}".utf8)]
        XCTAssertThrowsError(try admin.enable())
        tool.commands = []; tool.replies = [active, Data("ok".utf8), active]
        XCTAssertNoThrow(try admin.enable(), "A pending owned endpoint must remain retryable after approval")
    }

    // Implements: FR-SET-23, FR-SET-27
    func testExplicitTailscaleAuthHostnameCancelAndErrorsUseInjectedExecutor() throws {
        let tool = FakeTailscale(), admin = try TailscaleAdministration(root: root(), executor: tool)
        tool.replies = [Data("auth pending".utf8), Data("ok".utf8), Data("ok".utf8)]
        _ = try admin.signIn(); try admin.setHostname("work-host"); try admin.signOut(); admin.cancel()
        XCTAssertEqual(tool.commands, [["login"], ["set", "--hostname=work-host"], ["logout"]]); XCTAssertTrue(tool.cancelled)
        XCTAssertThrowsError(try admin.setHostname("bad; shell"))
        tool.exitCode = 1; tool.replies = [Data("daemon unavailable".utf8)]
        XCTAssertThrowsError(try admin.refresh())
    }

    // Implements: FR-SET-21, FR-SET-24, FR-SET-29, FR-SET-113, FR-SET-114
    func testGatewayAuthenticatesBeforeRoutingAndProvidesBoundOriginPreflight() throws {
        let pairing = try RemotePairingStore(root: root())
        var preferences = ServerPreferences(); preferences.serveOverTailscale = true; preferences.allowedOrigins = ["https://app.test"]
        var count = 0
        let gateway = RemoteHTTPGateway(pairing: pairing, preferences: { preferences }, ownLogin: { "me@test" }, route: { _ in count += 1; return APIResponse(result: .object(["ok": .bool(true)])) })
        let body = try JSONEncoder().encode(APIRequest(method: "server.info"))
        func request(headers: [String: String] = [:], method: String = "POST", path: String = "/api", data: Data? = nil) -> RemoteHTTPRequest {
            RemoteHTTPRequest(method: method, path: path, headers: headers, body: data ?? body)
        }
        XCTAssertEqual(gateway.respond(request(), proxy: TrustedTailscaleProxy()).status, 401); XCTAssertEqual(count, 0)
        let invitation = try pairing.invite()
        let payload = try JSONEncoder().encode(["code": invitation.code, "label": "Laptop"])
        let paired = gateway.respond(request(headers: ["tailscale-user-login": "me@test", "content-type": "application/json"], path: "/pair", data: payload), proxy: TrustedTailscaleProxy())
        XCTAssertEqual(paired.status, 200)
        let json = try JSONDecoder().decode([String: JSONValue].self, from: paired.body)
        let token = try XCTUnwrap(json["token"]?.text)
        let headers = ["authorization": "Bearer " + token, "tailscale-user-login": "me@test", "content-type": "application/json", "origin": "https://app.test"]
        XCTAssertEqual(gateway.respond(request(headers: headers), proxy: TrustedTailscaleProxy()).status, 200); XCTAssertEqual(count, 1)
        var bad = headers; bad["origin"] = "https://evil.test"
        XCTAssertEqual(gateway.respond(request(headers: bad), proxy: TrustedTailscaleProxy()).status, 403); XCTAssertEqual(count, 1)
        let preflight = gateway.respond(request(headers: ["origin": "https://app.test", "access-control-request-method": "POST", "access-control-request-headers": "authorization, content-type"], method: "OPTIONS"), proxy: TrustedTailscaleProxy())
        XCTAssertEqual(preflight.status, 204); XCTAssertEqual(preflight.headers["Access-Control-Allow-Origin"], "https://app.test")
    }

    // Implements: FR-SET-2
    func testAgentNamingChecksOptInGenerationAncestryWorkspaceAndExpectedTitle() throws {
        let path = try root(), runtime = try TerminalRuntime(root: path)
        let paneID = UUID().uuidString.lowercased(), generation = UUID().uuidString.lowercased()
        var launch = AgentLaunch(paneID: paneID, provider: .claude, cwd: "/tmp", accountID: nil, configurationRoot: "/tmp/fixture", bootID: "fixture")
        launch.id = generation; launch.providerPID = 42
        try runtime.update { state in
            state.sessions.append(TerminalSession(id: paneID, title: "Terminal", cwd: "/tmp", pid: 1))
            _ = state.layout.addWorkspace(title: "quiet-river"); state.layout.addTab(paneID: paneID)
            state.agentLaunches.append(launch)
        }
        let store = try SecureSettingsSidecar<IntegrationsPreferences>(root: path, filename: "integrations-settings.json")
        let initial = try store.load(); var enabled = initial; enabled.letAgentsNameSessions = true
        XCTAssertThrowsError(try runtime.nameAgentSession(paneID: paneID, generation: generation, expectedTitle: "quiet-river", title: "Fix tests", originPID: 40, verifyAncestry: { _, _, _ in true }))
        _ = try store.merge(baseline: initial, edited: enabled)
        XCTAssertThrowsError(try runtime.nameAgentSession(paneID: paneID, generation: "stale", expectedTitle: "quiet-river", title: "Fix tests", originPID: 40, verifyAncestry: { _, _, _ in true }))
        XCTAssertThrowsError(try runtime.nameAgentSession(paneID: paneID, generation: generation, expectedTitle: "quiet-river", title: "Fix tests", originPID: 40, verifyAncestry: { _, _, _ in false }))
        try runtime.nameAgentSession(paneID: paneID, generation: generation, expectedTitle: "quiet-river", title: "Fix tests", originPID: 40, verifyAncestry: { child, parent, provider in child == 40 && parent == 42 && provider == .claude })
        let layout = try runtime.state().layout
        XCTAssertEqual(layout.workspaces.first { $0.id == layout.selectedWorkspaceID }?.title, "Fix tests")
        XCTAssertThrowsError(try runtime.nameAgentSession(paneID: paneID, generation: generation, expectedTitle: "quiet-river", title: "Overwrite", originPID: 40, verifyAncestry: { _, _, _ in true }))
    }
}

private final class FakeTailscale: TailscaleCommandExecuting {
    var replies: [Data] = []
    var commands: [[String]] = []
    var exitCode: Int32 = 0
    var cancelled = false
    func run(arguments: [String]) throws -> TailscaleCommandResult {
        commands.append(arguments)
        guard !replies.isEmpty else { throw TerminalError.invalid("Missing fake reply") }
        return TailscaleCommandResult(exitCode: exitCode, output: replies.removeFirst())
    }
    func cancel() { cancelled = true }
}
