import XCTest
@testable import TerminalCore

final class RemoteTests: XCTestCase {
    // Implements: FR-REMOTE-2, FR-ACTIVITY-1
    func testRemoteActivityImportEmitsOneEventAndPreservesNavigation() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-sync-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try runtime.addRemoteHost(name: "Build", address: "build.example")
        var remote = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/work", pid: 12)
        var local = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/work", pid: 34)
        local.remote = RemoteReference(hostID: host.id, sessionID: remote.id)
        try runtime.update { $0.sessions.append(local); $0.layout.addTab(paneID: local.id) }
        let layout = try runtime.state().layout
        remote.agent = .codex
        remote.activity.state = .done
        remote.activity.reason = "Finished"
        remote.activity.source = "osc7501"
        try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
        let first = try runtime.state()
        XCTAssertEqual(first.events.last?.activity.state, .done)
        XCTAssertEqual(first.events.last?.sessionID, local.id)
        XCTAssertEqual(first.layout, layout)
        XCTAssertNil(first.navigationRequest)
        try runtime.importRemoteActivity(hostID: host.id, sessions: [remote])
        XCTAssertEqual(try runtime.state().revision, first.revision)
    }
    // Implements: FR-REMOTE-2
    func testHostRegistryIsPrivateAndRejectsRemovingAnAttachedHost() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-hosts-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try runtime.addRemoteHost(name: "Build", address: "build.example")
        XCTAssertEqual(try TerminalRuntime(root: root).state().remoteHosts, [host])
        XCTAssertThrowsError(try runtime.addRemoteHost(name: "Duplicate", address: "build.example"))
        try runtime.update { state in
            var pane = TerminalSession(id: UUID().uuidString, title: "Remote", cwd: "/work", pid: 12)
            pane.remote = RemoteReference(hostID: host.id, sessionID: UUID().uuidString)
            state.sessions.append(pane)
        }
        XCTAssertThrowsError(try runtime.removeRemoteHost(host.id))
        try runtime.update { $0.sessions = [] }
        try runtime.removeRemoteHost(host.id)
        XCTAssertTrue(try runtime.state().remoteHosts.isEmpty)
    }
    // Implements: FR-REMOTE-2
    func testSSHCommandPlanPreservesHostAndRejectsInjection() throws {
        let host = try RemoteHost(name: "Build Server", address: "dev@build.example")
        let id = UUID().uuidString.lowercased()
        let args = try RemoteClient(host: host).attachArguments(sessionID: id)
        XCTAssertEqual(args[args.count - 2], "dev@build.example")
        XCTAssertTrue(args.last!.contains(id))
        XCTAssertFalse(args.contains("StrictHostKeyChecking=no"))
        for value in ["-oProxyCommand=evil", "host;echo bad", "a b", "x\nwhoami", "$(whoami)", ""] {
            XCTAssertThrowsError(try RemoteHost(name: "bad", address: value))
        }
        XCTAssertThrowsError(try RemoteClient(host: host).attachArguments(sessionID: "; kill-server"))
    }
}
