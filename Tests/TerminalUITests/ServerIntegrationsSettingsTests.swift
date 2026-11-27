import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class ServerIntegrationsSettingsTests: XCTestCase {
    // Implements: FR-SET-20
    @MainActor func testManualServerRefreshIsStableAndOnlyEnabledForRestartRequired() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        let refresh = try XCTUnwrap(button("server-refresh-helper", in: view))
        XCTAssertFalse(refresh.isEnabled)
        let response = try JSONDecoder().decode(APIResponse.self, from: Data(("{\"apiVersion\":1,\"result\":{\"apiVersion\":1,\"version\":\"0.1.0\",\"buildNumber\":\"1\",\"buildID\":\"" + String(repeating: "b", count: 64) + "\",\"pid\":1234}}").utf8))
        let different = BuildIdentity(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "a", count: 64)])
        let same = BuildIdentity(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "b", count: 64)])
        let root = URL(fileURLWithPath: "/tmp/trano-fixture")
        let requiresRefresh = ServerRuntimeSnapshot(response: response, expected: different, root: root, label: "Desk")
        view.configure(preferences: ServerPreferences(), snapshot: requiresRefresh, tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        XCTAssertTrue(button("server-refresh-helper", in: view) === refresh)
        XCTAssertTrue(refresh.isEnabled)
        var action: ServerSettingsNativeAction?; view.onAction = { action = $0 }
        refresh.performClick(nil); XCTAssertEqual(action, .refreshServer)
        let compatible = ServerRuntimeSnapshot(response: response, expected: same, root: root, label: "Desk")
        view.configure(preferences: ServerPreferences(), snapshot: compatible, tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        XCTAssertFalse(refresh.isEnabled)
        view.configure(preferences: ServerPreferences(), snapshot: requiresRefresh, tailscale: nil, clients: [], toolAvailable: true, busy: true, error: nil)
        XCTAssertFalse(refresh.isEnabled)
    }

    @MainActor private final class EditorFixture: NSTextView {
        var composing = false
        override func hasMarkedText() -> Bool { composing }
    }

    // Implements: FR-SET-23, FR-SET-28, FR-SET-29
    @MainActor func testRefreshKeepsServerControlTreeAndUpdatesCurrentDraftCallbacks() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        var preferences = ServerPreferences(); preferences.clientLabel = "Desk"; preferences.preferredHostname = "desk-host"
        view.configure(preferences: preferences, snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        let tree = try XCTUnwrap(view.subviews.first)
        let label = try XCTUnwrap(text("server-label", in: view))
        let hostname = try XCTUnwrap(text("server-hostname", in: view))
        let remote = try XCTUnwrap(button("server-remote-control", in: view))
        preferences.clientLabel = "Updated"; preferences.preferredHostname = "updated-host"; preferences.limitToSameAccount = false
        view.configure(preferences: preferences, snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: "status update")
        XCTAssertTrue(view.subviews.first === tree)
        XCTAssertTrue(text("server-label", in: view) === label)
        XCTAssertTrue(text("server-hostname", in: view) === hostname)
        XCTAssertTrue(button("server-remote-control", in: view) === remote)
        XCTAssertEqual(label.stringValue, "Updated"); XCTAssertEqual(hostname.stringValue, "updated-host")
        var changed: ServerPreferences?; view.onChange = { changed = $0 }
        remote.performClick(nil)
        XCTAssertEqual(changed?.clientLabel, "Updated"); XCTAssertEqual(changed?.preferredHostname, "updated-host")
        XCTAssertEqual(changed?.limitToSameAccount, false)
    }

    // Implements: FR-SET-23, FR-SET-28
    @MainActor func testComposingServerEditorSurvivesRefreshAndCommitsAgainstLatestDraft() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        let label = try XCTUnwrap(text("server-label", in: view) as? ServerSettingsTextField)
        let editor = EditorFixture(frame: .zero); editor.string = "한국"; editor.composing = true
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        label.editorProvider = { editor }
        var changes: [ServerPreferences] = []; view.onChange = { changes.append($0) }
        var refreshed = ServerPreferences(); refreshed.clientLabel = "External"; refreshed.remoteControl = true
        refreshed.preferredHostname = "new-host"
        view.configure(preferences: refreshed, snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: true, error: nil)
        XCTAssertTrue(text("server-label", in: view) === label)
        XCTAssertEqual(editor.string, "한국"); XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(label.stringValue, "Trano")
        label.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: label))
        XCTAssertTrue(changes.isEmpty)
        editor.composing = false; editor.string = "한국어"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        label.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: label))
        XCTAssertEqual(changes.last?.clientLabel, "한국어")
        XCTAssertEqual(changes.last?.preferredHostname, "new-host")
        XCTAssertEqual(changes.last?.remoteControl, true)
        view.configure(preferences: try XCTUnwrap(changes.last), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        XCTAssertTrue(text("server-label", in: view) === label)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
    }

    // Implements: FR-SET-29
    @MainActor func testPairedClientActionsRetainIdentityAndUseRefreshedPermission() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        let client = AuthorizedRemoteClient(id: "retained-client", label: "Laptop", createdAt: Date(timeIntervalSince1970: 1), remoteControl: false)
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [client], toolAvailable: true, busy: false, error: nil)
        let control = try XCTUnwrap(button("server-client-control-retained-client", in: view))
        let updated = AuthorizedRemoteClient(id: client.id, label: "New Laptop", createdAt: client.createdAt, remoteControl: true)
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [updated], toolAvailable: true, busy: false, error: nil)
        XCTAssertTrue(button("server-client-control-retained-client", in: view) === control)
        XCTAssertEqual(control.state, .on)
        var action: ServerSettingsNativeAction?; view.onAction = { action = $0 }
        control.performClick(nil)
        XCTAssertEqual(action, .setClientRemoteControl("retained-client", false))
    }

    // Implements: FR-SET-1, FR-SET-2
    @MainActor func testIntegrationRefreshRetainsControlsAndCurrentNamingValue() throws {
        let view = IntegrationsSettingsNativeView(frame: .zero)
        var preferences = IntegrationsPreferences(); preferences.integrateWithAvailableAgents = true
        view.configure(preferences: preferences, available: [.claude], installed: [], busy: false)
        let master = try XCTUnwrap(button("integrations-enabled", in: view))
        let naming = try XCTUnwrap(button("integrations-agent-naming", in: view))
        preferences.letAgentsNameSessions = true
        view.configure(preferences: preferences, available: [.claude, .codex], installed: [.claude], busy: false)
        XCTAssertTrue(button("integrations-enabled", in: view) === master)
        XCTAssertTrue(button("integrations-agent-naming", in: view) === naming)
        var changed: IntegrationsPreferences?; view.onChange = { changed = $0 }
        naming.performClick(nil)
        XCTAssertEqual(changed?.letAgentsNameSessions, false)
        XCTAssertEqual(changed?.integrateWithAvailableAgents, true)
    }

    // Implements: FR-SET-21, FR-SET-22
    @MainActor func testRemoteAddressRequiresActualBridgeReadiness() throws {
        var preferences = ServerPreferences(); preferences.serveOverTailscale = true
        let tailscale = try TailscaleSnapshot(data: Data(#"{"BackendState":"Running","Self":{"DNSName":"node.example.test."}}"#.utf8))
        let view = ServerSettingsNativeView(frame: .zero)
        view.configure(preferences: preferences, snapshot: snapshot(), tailscale: tailscale, clients: [], toolAvailable: true, busy: false, error: nil)
        XCTAssertEqual(try XCTUnwrap(text("server-remote-address", in: view)).stringValue, "Unavailable")
        XCTAssertFalse(try XCTUnwrap(button("server-pair", in: view)).isEnabled)
    }
    @MainActor private func button(_ id: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
        for child in view.subviews { if let result = button(id, in: child) { return result } }
        return nil
    }
    @MainActor private func text(_ id: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == id { return field }
        for child in view.subviews { if let result = text(id, in: child) { return result } }
        return nil
    }
    @MainActor private func snapshot() -> ServerRuntimeSnapshot {
        ServerRuntimeSnapshot(response: nil, expected: .process, root: URL(fileURLWithPath: "/tmp/trano-fixture"), label: "Desktop")
    }

    // Implements: FR-SET-19, FR-SET-20, FR-SET-22, FR-SET-27, FR-SET-28, FR-SET-29
    @MainActor func testServerNativeControlsOwnActionsAndEditOnlyDraft() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        var changes: [ServerPreferences] = [], actions: [ServerSettingsNativeAction] = []
        view.onChange = { changes.append($0) }; view.onAction = { actions.append($0) }
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        let remote = try XCTUnwrap(button("server-remote-control", in: view)); remote.performClick(nil)
        XCTAssertEqual(changes.last?.remoteControl, true); XCTAssertTrue(actions.isEmpty)
        remote.performClick(nil)
        XCTAssertEqual(changes.last?.remoteControl, false)
        let refresh = try XCTUnwrap(button("server-refresh", in: view)); refresh.performClick(nil)
        XCTAssertEqual(actions, [.refresh])
        view.configure(preferences: changes.last ?? ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: false, error: nil)
        try XCTUnwrap(button("server-sign-in", in: view)).performClick(nil)
        XCTAssertEqual(actions.last, .signIn)
    }

    // Implements: FR-SET-21, FR-SET-22, FR-SET-25, FR-SET-26, FR-SET-27
    @MainActor func testAbsentToolAndBusyStatesDisableUnavailableActionsWithoutInventingStatus() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: false, busy: false, error: nil)
        XCTAssertFalse(try XCTUnwrap(button("server-sign-in", in: view)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(button("server-serve", in: view)).isEnabled)
        XCTAssertEqual(try XCTUnwrap(text("server-tags", in: view)).stringValue, "Unavailable")
        XCTAssertEqual(try XCTUnwrap(text("server-control-server", in: view)).stringValue, "Unavailable")
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [], toolAvailable: true, busy: true, error: nil)
        XCTAssertFalse(try XCTUnwrap(button("server-refresh", in: view)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(button("server-cancel", in: view)).isEnabled)
    }

    // Implements: FR-SET-21, FR-SET-24, FR-SET-29, FR-SET-112
    @MainActor func testClientPermissionsRevokeAndCopyEndpointUseExplicitNativeActions() throws {
        let view = ServerSettingsNativeView(frame: .zero)
        let client = AuthorizedRemoteClient(id: "client-fixture", label: "Laptop", createdAt: Date(timeIntervalSince1970: 1), remoteControl: false)
        var actions: [ServerSettingsNativeAction] = []
        view.onAction = { actions.append($0) }
        view.configure(preferences: ServerPreferences(), snapshot: snapshot(), tailscale: nil, clients: [client], toolAvailable: true, busy: false, error: nil)
        try XCTUnwrap(button("server-client-control-client-fixture", in: view)).performClick(nil)
        XCTAssertEqual(actions.last, .setClientRemoteControl("client-fixture", true))
        try XCTUnwrap(button("server-client-revoke-client-fixture", in: view)).performClick(nil)
        XCTAssertEqual(actions.last, .revokeClient("client-fixture"))
        try XCTUnwrap(button("server-copy-local-api", in: view)).performClick(nil)
        XCTAssertEqual(actions.last, .copyLocalAPI)
        XCTAssertEqual(try XCTUnwrap(text("server-local-api", in: view)).stringValue, "unix:///tmp/trano-fixture/api.sock")
    }

    // Implements: FR-SET-1, FR-SET-2
    @MainActor func testIntegrationMasterOwnsToggleAndHidesAgentNamingUntilEnabled() throws {
        let view = IntegrationsSettingsNativeView(frame: .zero)
        var preferences = IntegrationsPreferences(); preferences.integrateWithAvailableAgents = false
        var changes: [IntegrationsPreferences] = []
        view.onChange = { changes.append($0) }
        view.configure(preferences: preferences, available: [.claude, .codex], installed: [], busy: false)
        XCTAssertNil(button("integrations-agent-naming", in: view))
        try XCTUnwrap(button("integrations-enabled", in: view)).performClick(nil)
        XCTAssertTrue(try XCTUnwrap(changes.last).integrateWithAvailableAgents)
        view.configure(preferences: try XCTUnwrap(changes.last), available: [.claude, .codex], installed: [.claude], busy: false)
        try XCTUnwrap(button("integrations-agent-naming", in: view)).performClick(nil)
        XCTAssertTrue(try XCTUnwrap(changes.last).letAgentsNameSessions)
    }
}
