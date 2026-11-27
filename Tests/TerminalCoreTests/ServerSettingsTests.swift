import Foundation
import XCTest
@testable import TerminalCore

final class ServerSettingsTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-settings-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // Implements: FR-SET-22, FR-SET-24, FR-SET-28, FR-SET-29
    func testServerDefaultsPreserveLocalAccessWithoutNetworkExposure() throws {
        let root = try temporaryRoot()
        let store = try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json")
        XCTAssertEqual(try store.load(), ServerPreferences())
        XCTAssertFalse(try store.load().serveOverTailscale)
        XCTAssertFalse(try store.load().remoteControl)
        XCTAssertTrue(try store.load().limitToSameAccount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("server-settings.json").path))
    }

    // Implements: FR-SET-23, FR-SET-28, FR-SET-29
    func testSidecarMergesOnlyChangedFieldsAndIgnoresPrimaryRewrite() throws {
        let root = try temporaryRoot()
        let store = try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json")
        let baseline = try store.load()
        var first = baseline; first.clientLabel = "Desktop"
        _ = try store.merge(baseline: baseline, edited: first)
        var second = baseline; second.preferredHostname = "trano-work"
        let merged = try store.merge(baseline: baseline, edited: second)
        XCTAssertEqual(merged.clientLabel, "Desktop")
        XCTAssertEqual(merged.preferredHostname, "trano-work")
        try Data("{\"schemaVersion\":1}".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertEqual(try store.load(), merged)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("server-settings.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Implements: FR-SET-28
    func testInvalidDraftDoesNotPartiallyWriteAndCancelNeedsNoWrite() throws {
        let root = try temporaryRoot()
        let store = try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json")
        let baseline = try store.load()
        var draft = baseline; draft.clientLabel = "bad\nlabel"; draft.remoteControl = true
        XCTAssertThrowsError(try store.merge(baseline: baseline, edited: draft))
        XCTAssertEqual(try store.load(), baseline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("server-settings.json").path))
    }

    // Implements: FR-SET-28
    func testSidecarRefusesSymlinkAndUnknownSchema() throws {
        let root = try temporaryRoot()
        let target = root.appendingPathComponent("private.json")
        try Data("{}".utf8).write(to: target)
        let path = root.appendingPathComponent("server-settings.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        let store = try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json")
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: path)
        try Data("{\"schemaVersion\":99,\"values\":{}}".utf8).write(to: path)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "../escape.json"))
    }

    // Implements: FR-SET-113, FR-SET-114
    func testOriginMatchingIsSchemeHostPortBoundAndWildcardNeedsSubdomain() throws {
        let origin = try RemoteOriginPattern("https://Example.com:443")
        XCTAssertEqual(origin.canonical, "https://example.com")
        XCTAssertTrue(origin.matches("https://example.com"))
        XCTAssertFalse(origin.matches("http://example.com"))
        XCTAssertFalse(origin.matches("https://example.com.evil.test"))
        let wildcard = try RemoteOriginPattern("https://*.example.com:8443")
        XCTAssertTrue(wildcard.matches("https://app.example.com:8443"))
        XCTAssertFalse(wildcard.matches("https://example.com:8443"))
        XCTAssertFalse(wildcard.matches("https://app.example.com"))
    }

    // Implements: FR-SET-113, FR-SET-114
    func testOriginsRejectOpaquePathsCredentialsQueriesAndBroadWildcards() {
        for value in ["null", "*", "https://*.com", "https://user@example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com#fragment", "file://example.com", "https://example.com\n"] {
            XCTAssertThrowsError(try RemoteOriginPattern(value), value)
        }
    }

    // Implements: FR-SET-22, FR-SET-23, FR-SET-27
    func testTailscaleCommandsUseArgumentArraysAndOwnedServePath() {
        XCTAssertEqual(TailscaleCommand.status.arguments, ["status", "--json"])
        XCTAssertEqual(TailscaleCommand.serve(target: "unix:/tmp/fixture/r.sock").arguments, ["serve", "--bg", "--https=443", "--set-path=/trano", "unix:/tmp/fixture/r.sock"])
        XCTAssertEqual(TailscaleCommand.stopServing.arguments, ["serve", "--https=443", "--set-path=/trano", "off"])
        XCTAssertEqual(TailscaleCommand.signIn.arguments, ["login"])
        XCTAssertEqual(TailscaleCommand.signOut.arguments, ["logout"])
        XCTAssertEqual(TailscaleCommand.setHostname("work-host").arguments, ["set", "--hostname=work-host"])
    }

    // Implements: FR-SET-21, FR-SET-25, FR-SET-26
    func testTailscaleSnapshotUsesOwnUserIdentityAndStatusWithoutInventingMetadata() throws {
        let data = Data(#"{"BackendState":"Running","Self":{"DNSName":"trano.tail.test.","UserID":42,"Tags":["tag:dev"]},"User":{"42":{"LoginName":"me@example.test"}},"CurrentTailnet":{"MagicDNSSuffix":"tail.test"}}"#.utf8)
        let status = try TailscaleSnapshot(data: data)
        XCTAssertEqual(status.loginName, "me@example.test")
        XCTAssertEqual(status.tags, ["tag:dev"])
        XCTAssertEqual(status.remoteAddress?.absoluteString, "https://trano.tail.test/trano")
        XCTAssertNil(status.controlURL)
    }

    // Implements: FR-SET-21, FR-SET-24, FR-SET-28, FR-SET-29
    func testPairingIsSingleUseExpiringAndPersistsOnlyHashedCredentials() throws {
        let root = try temporaryRoot(); let store = try RemotePairingStore(root: root)
        var preferences = ServerPreferences(); preferences.serveOverTailscale = true
        let now = Date(timeIntervalSince1970: 100)
        let invitation = try store.invite(now: now)
        let credential = try store.pair(code: invitation.code, label: "Laptop", login: "me@test", ownLogin: "me@test", preferences: preferences, now: now)
        XCTAssertEqual(credential.client.label, "Laptop")
        XCTAssertThrowsError(try store.pair(code: invitation.code, label: "Again", login: "me@test", ownLogin: "me@test", preferences: preferences, now: now))
        let expired = try store.invite(now: now)
        XCTAssertThrowsError(try store.pair(code: expired.code, label: "Too late", login: "me@test", ownLogin: "me@test", preferences: preferences, now: now.addingTimeInterval(121)))
        let text = try String(contentsOf: root.appendingPathComponent("remote-clients.json"), encoding: .utf8)
        XCTAssertFalse(text.contains(credential.token)); XCTAssertFalse(text.contains(invitation.code))
        XCTAssertEqual(try RemotePairingStore(root: root).clients().count, 1)
    }

    // Implements: FR-SET-24, FR-SET-29, FR-SET-113
    func testPairingAuthorizationChecksAccountOriginRemoteControlAndRevocation() throws {
        let store = try RemotePairingStore(root: temporaryRoot())
        var preferences = ServerPreferences(); preferences.serveOverTailscale = true; preferences.allowedOrigins = ["https://app.example.test"]
        let code = try store.invite().code
        let credential = try store.pair(code: code, label: "Laptop", login: "me@test", ownLogin: "me@test", preferences: preferences)
        func authorize(_ method: String, origin: String? = nil, login: String? = "me@test") throws -> AuthorizedRemoteClient {
            try store.authorize(token: credential.token, origin: origin, login: login, ownLogin: "me@test", method: method, preferences: preferences)
        }
        XCTAssertEqual(try authorize("server.info").id, credential.client.id)
        XCTAssertThrowsError(try authorize("server.info", login: "other@test"))
        XCTAssertThrowsError(try authorize("server.info", origin: "https://evil.test"))
        XCTAssertEqual(try authorize("server.info", origin: "https://app.example.test").id, credential.client.id)
        XCTAssertThrowsError(try authorize("panes.send"))
        preferences.remoteControl = true
        XCTAssertThrowsError(try authorize("panes.send"))
        try store.setRemoteControl(id: credential.client.id, allowed: true)
        XCTAssertEqual(try authorize("panes.send").id, credential.client.id)
        XCTAssertThrowsError(try authorize("service.shutdown"))
        try store.revoke(id: credential.client.id)
        XCTAssertThrowsError(try authorize("server.info"))
    }

    // Implements: FR-SET-1, FR-SET-2
    func testAgentNamingRequiresBothIntegrationAndNamingOptIn() {
        var value = IntegrationsPreferences()
        XCTAssertFalse(value.permitsSessionNaming)
        value.letAgentsNameSessions = true
        XCTAssertTrue(value.permitsSessionNaming)
        value.integrateWithAvailableAgents = false
        XCTAssertFalse(value.permitsSessionNaming)
    }

    // Implements: FR-SET-21, FR-SET-29, FR-SET-113
    func testHTTPParserSupportsIncrementalBoundedRequestsAndRejectsAmbiguity() throws {
        let body = Data(#"{"method":"server.info","apiVersion":1,"params":{}}"#.utf8)
        let head = "POST /trano/api HTTP/1.1\r\nHost: trano.test\r\nAuthorization: Bearer example\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        XCTAssertNil(try RemoteHTTPRequest.parse(Data(head.utf8)))
        let parsed = try XCTUnwrap(RemoteHTTPRequest.parse(Data(head.utf8) + body))
        XCTAssertEqual(parsed.path, "/api"); XCTAssertEqual(parsed.headers["authorization"], "Bearer example")
        XCTAssertEqual(parsed.body, body)
        for text in ["POST /api HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx", "POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "POST /api HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n", "POST /api?token=secret HTTP/1.1\r\nContent-Length: 0\r\n\r\n"] {
            XCTAssertThrowsError(try RemoteHTTPRequest.parse(Data(text.utf8)))
        }
    }

    // Implements: FR-SET-1, FR-SET-2
    func testManagedIntegrationInstallsOnlyOwnedFilesAndRemovesWithReceipt() throws {
        let root = try temporaryRoot(); let installer = try ManagedAgentIntegration(root: root)
        var preferences = IntegrationsPreferences()
        let enabled = try installer.plan(provider: .claude, preferences: preferences)
        XCTAssertTrue(enabled.files.keys.contains("claude/skills/trano/SKILL.md"))
        let skill = try XCTUnwrap(enabled.files["claude/skills/trano/SKILL.md"])
        XCTAssertFalse(String(decoding: skill, as: UTF8.self).contains("agent.name-session"))
        try installer.apply(enabled)
        preferences.letAgentsNameSessions = true
        let named = try installer.plan(provider: .claude, preferences: preferences)
        XCTAssertTrue(String(decoding: try XCTUnwrap(named.files["claude/skills/trano/SKILL.md"]), as: UTF8.self).contains("agent.name-session"))
        try installer.apply(named)
        preferences.integrateWithAvailableAgents = false
        try installer.apply(installer.plan(provider: .claude, preferences: preferences))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("integration/agents/claude/skills/trano/SKILL.md").path))
    }

    // Implements: FR-SET-1
    func testManagedIntegrationRefusesUnmanagedAndModifiedFiles() throws {
        let root = try temporaryRoot(); let installer = try ManagedAgentIntegration(root: root)
        let plan = try installer.plan(provider: .codex, preferences: IntegrationsPreferences())
        try installer.apply(plan)
        let skill = root.appendingPathComponent("integration/agents/codex/skills/trano/SKILL.md")
        try Data("user edited skill\n".utf8).write(to: skill)
        var off = IntegrationsPreferences(); off.integrateWithAvailableAgents = false
        XCTAssertThrowsError(try installer.apply(installer.plan(provider: .codex, preferences: off)))
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "user edited skill\n")
    }
}
