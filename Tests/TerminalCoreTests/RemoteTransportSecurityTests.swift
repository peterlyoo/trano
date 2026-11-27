import Foundation
import XCTest
@testable import TerminalCore
final class RemoteTransportSecurityTests: XCTestCase {
    private func root() throws -> URL {
        let path = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-sec-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }; return path
    }
    // Implements: FR-SET-21, FR-SET-24, FR-SET-29
    func testForgedLocalhostIdentityWithoutVerifiedProxyCannotUseValidBearer() throws {
        let pairing = try RemotePairingStore(root: root())
        var preferences = ServerPreferences(); preferences.serveOverTailscale = true
        let credential = try pairing.pair(code: pairing.invite().code, label: "Fixture", login: "owner@test", ownLogin: "owner@test", preferences: preferences)
        var routed = 0
        let gateway = RemoteHTTPGateway(pairing: pairing, preferences: { preferences }, ownLogin: { "owner@test" }, route: { _ in routed += 1; return APIResponse(result: .bool(true)) })
        let request = RemoteHTTPRequest(method: "POST", path: "/api", headers: ["authorization": "Bearer " + credential.token, "content-type": "application/json", "tailscale-user-login": "owner@test"], body: try JSONEncoder().encode(APIRequest(method: "server.info")))
        XCTAssertEqual(gateway.respond(request).status, 403); XCTAssertEqual(routed, 0)
        XCTAssertEqual(gateway.respond(request, proxy: TrustedTailscaleProxy()).status, 200); XCTAssertEqual(routed, 1)
    }
    // Implements: FR-SET-21, FR-SET-24
    func testKernelPeerPolicyRequiresTrustedDaemonAndRejectsOtherLocalUsers() {
        func allowed(_ uid: UInt32, _ name: String, signed: Bool = false, rootOwned: Bool = false) -> Bool {
            TailscaleProxyPeerPolicy.allows(TailscaleProxyPeerFacts(uid: uid, ownerUID: 502, pid: 123, executableName: name, validTailscaleSignature: signed, rootOwnedUnwritableExecutable: rootOwned))
        }
        XCTAssertFalse(allowed(503, "IPNExtension", signed: true))
        XCTAssertFalse(allowed(502, "curl"))
        XCTAssertFalse(allowed(502, "tailscaled", rootOwned: true))
        XCTAssertFalse(allowed(0, "unrelated-daemon", rootOwned: true))
        XCTAssertTrue(allowed(0, "tailscaled", rootOwned: true))
        XCTAssertTrue(allowed(502, "IPNExtension", signed: true))
    }
    // Implements: FR-SET-21, FR-SET-22
    func testReservedServeSubtreeRejectsForeignDescendantsBeforeMutation() throws {
        for path in ["/trano/api", "/trano/pair", "/trano/api/nested", "/%74rano/api"] {
            let tool = SubtreeTailscale(path: path), admin = try TailscaleAdministration(root: root(), executor: tool)
            XCTAssertThrowsError(try admin.enable())
            XCTAssertEqual(tool.calls, [["serve", "status", "--json"]], path)
        }
    }
}
private final class SubtreeTailscale: TailscaleCommandExecuting {
    var calls: [[String]] = []
    let path: String
    init(path: String) { self.path = path }
    func run(arguments: [String]) throws -> TailscaleCommandResult {
        calls.append(arguments)
        let value = JSONValue.object(["Web": .object(["node.test:443": .object(["Handlers": .object([path: .object(["Proxy": .string("http://127.0.0.1:9999")])])])])])
        return TailscaleCommandResult(exitCode: 0, output: try JSONEncoder().encode(value))
    }
    func cancel() {}
}
