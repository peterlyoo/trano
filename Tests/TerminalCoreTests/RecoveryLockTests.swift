import XCTest
@testable import TerminalCore

final class RecoveryLockTests: XCTestCase {
    // Implements: U01, U07, FR-RECOVERY-2
    func testSSHRecoveryNeverBlocksLocalStateMutation() throws {
        for entry in ["bridge", "recovery", "action"] {
            let root = URL(fileURLWithPath: "/tmp/trano-lock-" + UUID().uuidString.prefix(6))
            let runtime = try TerminalRuntime(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let ready = root.appendingPathComponent("ssh-entered")
            let config = root.appendingPathComponent("ssh-config")
            try "Host trano-lock-fixture\n HostName 127.0.0.1\n User fixture\n ProxyCommand /bin/sh -c '/usr/bin/touch \(ready.path); exec /bin/sleep 2'\n".write(to: config, atomically: true, encoding: .utf8)
            let host = try runtime.addRemoteHost(name: "Fixture", address: "trano-lock-fixture", sshConfigPath: config.path)
            var pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/tmp", pid: 1)
            pane.remote = RemoteReference(hostID: host.id, sessionID: UUID().uuidString.lowercased())
            try runtime.update { $0.sessions.append(pane); $0.layout.addTab(paneID: pane.id) }
            let operation = expectation(description: "SSH operation returned")
            DispatchQueue.global().async {
                defer { operation.fulfill() }
                switch entry {
                case "bridge": try? runtime.restoreRemoteBridge(pane.id)
                case "recovery": _ = try? runtime.recoverSessions()
                default: try? runtime.performAction(.restoreSessions)
                }
            }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), entry)
            let other = try TerminalRuntime(root: root)
            let start = Date()
            try other.report(pane.id, state: .blocked, reason: "Local hook", agent: .claude, source: "hook")
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, entry + " held the state lock during SSH")
            wait(for: [operation], timeout: 12)
        }
    }
}
