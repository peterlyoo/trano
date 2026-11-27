import XCTest
@testable import TerminalCore

// Implements: FR-CLOSE-1, FR-CLOSE-2, FR-CLOSE-3, FR-CLOSE-5, FR-CLOSE-7
final class ClosedTerminalLifecycleTests: XCTestCase {
    func testCloseStopsCapturedPaneAndReopenCreatesFreshShell() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        try f.runtime.performAction(.closePane)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertTrue(try f.commands().contains("capture "))
        XCTAssertTrue(try f.commands().contains("kill "))
        try f.runtime.performAction(.restoreTab)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertEqual(try f.runtime.state().layout.focusedPaneID, pane.id)
        XCTAssertEqual(try f.commands().components(separatedBy: "create ").count - 1, 2)
    }

    func testCaptureFailureDoesNotCloseOrKill() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let before = try f.runtime.state().layout
        try Data().write(to: f.root.appendingPathComponent("fail-capture"))
        XCTAssertThrowsError(try f.runtime.performAction(.closePane))
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first(where: { $0.id == pane.id })).alive)
        XCTAssertFalse(try f.commands().contains("kill "))
    }

    func testWholeTabCapturesAllPanesBeforeFirstStopAndRestoresTree() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        _ = try f.addPane(); _ = try f.addPane(split: true)
        let before = try f.runtime.state().layout
        try f.runtime.performAction(.closeTab)
        let operations = try f.commands().components(separatedBy: "\n")
        let captures = operations.indices.filter { operations[$0].hasPrefix("capture ") }
        let firstKill = try XCTUnwrap(operations.firstIndex(where: { $0.hasPrefix("kill ") }))
        XCTAssertEqual(captures.count, 2)
        XCTAssertTrue(captures.allSatisfy { $0 < firstKill })
        XCTAssertEqual(try f.runtime.list().filter(\.alive).count, 0)
        try f.runtime.performAction(.restoreTab)
        XCTAssertEqual(try f.runtime.state().layout.tabs, before.tabs)
        XCTAssertEqual(try f.runtime.list().filter(\.alive).count, 2)
    }

    func testPartialStopFailureRetainsSavedStateAndReopenDoesNotDuplicateSurvivor() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let first = try f.addPane(); let second = try f.addPane(split: true)
        try Data().write(to: f.root.appendingPathComponent("fail-kill-" + second.id))
        XCTAssertThrowsError(try f.runtime.performAction(.closeTab))
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first(where: { $0.id == first.id })).alive)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first(where: { $0.id == second.id })).alive)
        XCTAssertNotNil(try f.runtime.closedTerminalPaneSnapshot(first.id))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("fail-kill-" + second.id))
        try f.runtime.performAction(.restoreTab)
        XCTAssertEqual(try f.runtime.state().layout.tabs.flatMap(\.panes).count, 2)
        XCTAssertEqual(try f.runtime.list().filter(\.alive).count, 2)
        XCTAssertEqual(try f.commands().components(separatedBy: "create ").count - 1, 3)
    }

    func testIntentionallyClosedPaneSurvivesLegacyRewriteAndGenericRecovery() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let legacy = try Data(contentsOf: f.root.appendingPathComponent("state.json"))
        try f.runtime.performAction(.closePane)
        try TerminalRuntime.atomicWrite(legacy, to: f.root.appendingPathComponent("state.json"))
        try TerminalRuntime.atomicWrite(Data("{\"activityReadAt\":{},\"followUpInputs\":[],\"followUpTurns\":[],\"followUpPasteStates\":[]}".utf8), to: f.root.appendingPathComponent("continuity.json"))
        XCTAssertTrue(try f.runtime.isTerminalIntentionallyClosed(pane.id))
        XCTAssertTrue(try f.runtime.recoverSessions().isEmpty)
        XCTAssertEqual(try f.commands().components(separatedBy: "create ").count - 1, 1)
        try f.runtime.restoreClosedTerminal()
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertFalse(try f.runtime.isTerminalIntentionallyClosed(pane.id))
    }

    func testStoredShellAndScreenUsedInsteadOfChangedDefault() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane(shell: "/bin/bash")
        try f.runtime.performAction(.closePane)
        let snapshot = try XCTUnwrap(f.runtime.closedTerminalPaneSnapshot(pane.id))
        XCTAssertEqual(snapshot.shell.executable, "/bin/bash")
        let contents = try f.runtime.closedTerminalStore.contents(id: snapshot.archiveID)
        XCTAssertTrue(contents.screen.contains("saved output 한글"))
        try f.runtime.performAction(.restoreTab)
        let commands = try f.commands()
        XCTAssertTrue(commands.contains("trano-reopen"))
        XCTAssertTrue(commands.contains("/bin/bash"))
        XCTAssertTrue(commands.contains(".screen"))
    }

    func testCreateFailureRetainsReopenEntryAndRetryWorks() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        try f.runtime.performAction(.closePane)
        try Data().write(to: f.root.appendingPathComponent("fail-create"))
        XCTAssertThrowsError(try f.runtime.performAction(.restoreTab))
        XCTAssertFalse(try f.runtime.state().layout.closedTabs.isEmpty)
        XCTAssertTrue(try f.runtime.isTerminalIntentionallyClosed(pane.id))
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("fail-create"))
        try f.runtime.performAction(.restoreTab)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertTrue(try f.runtime.state().layout.closedTabs.isEmpty)
    }


    func testConcurrentCloseAndReopenLeaseDoesNotMutateTarget() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        _ = try f.addPane()
        try f.runtime.closedTerminalStore.operation {
            XCTAssertThrowsError(try f.runtime.performAction(.closePane))
            XCTAssertThrowsError(try f.runtime.restoreClosedTerminal())
        }
        XCTAssertFalse(try f.commands().contains("kill "))
        try f.runtime.performAction(.closePane)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first).alive)
    }

    func testReopenSiblingDoesNotResurrectAnAlreadyReopenedPane() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let first = try f.addPane()
        try f.runtime.performAction(.closePane); try f.runtime.performAction(.restoreTab)
        let second = try f.addPane(split: true)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(first.id + ".live"))
        try f.runtime.performAction(.closePane); try f.runtime.performAction(.restoreTab)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first(where: { $0.id == first.id })).alive)
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first(where: { $0.id == second.id })).alive)
        XCTAssertEqual(try f.commands().components(separatedBy: "create ").count - 1, 4)
    }

    func testReopenAdoptsItsNewShellAfterInterruptedCommit() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        try f.runtime.performAction(.closePane)
        var ledger = try f.runtime.closedTerminalStore.ledger()
        let snapshot = try XCTUnwrap(ledger.panes[pane.id])
        ledger.panes[pane.id]?.phase = .restoring
        try f.runtime.closedTerminalStore.save(ledger)
        _ = try f.runtime.create(title: pane.title, cwd: pane.cwd, shell: snapshot.shell.executable,
            arguments: snapshot.shell.arguments, restoringID: pane.id, closedArchiveID: snapshot.archiveID)
        try f.runtime.restoreClosedTerminal()
        XCTAssertEqual(try f.commands().components(separatedBy: "create ").count - 1, 2)
        XCTAssertEqual(try f.runtime.closedTerminalPaneSnapshot(pane.id)?.phase, .reopened)
        XCTAssertEqual(try f.runtime.state().layout.focusedPaneID, pane.id)
    }

    func testStaleMonitorAndDirectoryCallbacksCannotChangeFreshShell() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let report = ActivityReport(state: .done, agent: .claude, reason: "stale", clearsActive: false)
        try f.runtime.report(pane.id, report: report, expectedPID: pane.pid + 1)
        try f.runtime.recordDirectory(paneID: pane.id, cwd: "/stale", expectedPID: pane.pid + 1)
        XCTAssertEqual(try f.runtime.state().sessions.first?.activity.state, .unknown)
        XCTAssertEqual(try f.runtime.state().sessions.first?.cwd, pane.cwd)
        try f.runtime.performAction(.closePane)
        try f.runtime.report(pane.id, report: report, expectedPID: pane.pid)
        try f.runtime.recordDirectory(paneID: pane.id, cwd: "/stale", expectedPID: pane.pid)
        XCTAssertEqual(try f.runtime.state().sessions.first?.activity.state, .unknown)
        XCTAssertEqual(try f.runtime.state().sessions.first?.cwd, pane.cwd)
    }

    func testMovedCloseTargetIsRejectedAtFinalValidation() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        var validation = 0
        XCTAssertThrowsError(try f.runtime.closeTerminalPane(pane.id, validate: { _ in
            validation += 1
            if validation == 2 {
                try f.runtime.update { state in
                    state.layout.detach(pane.id)
                    state.layout.addWorkspace(title: "moved-target")
                    state.layout.addTab(paneID: pane.id)
                }
                throw TerminalError.invalid("Target moved")
            }
        }))
        XCTAssertFalse(try f.commands().contains("kill "))
    }

    func testShellSelectionDoesNotReplayCommands() {
        XCTAssertEqual(ClosedTerminalShell.safe(.init(executable: "/bin/bash", arguments: ["-lc", "touch /tmp/never"])), .init(executable: "/bin/bash", arguments: ["-l"]))
        XCTAssertEqual(ClosedTerminalShell.safe(.init(executable: "/usr/bin/python3", arguments: ["job.py"])), .init(executable: "/bin/zsh", arguments: ["-l"]))
    }

    func testInterruptedCloseRetainsOriginalArchiveAndProcessWitnesses() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let layout = try f.runtime.state().layout
        try f.runtime.closeTerminalPane(pane.id)
        var ledger = try f.runtime.closedTerminalStore.ledger()
        var snapshot = try XCTUnwrap(ledger.panes[pane.id])
        snapshot.phase = .closing
        snapshot.processWitnesses = [.init(pid: 900012, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 0)]
        ledger.panes[pane.id] = snapshot
        try f.runtime.closedTerminalStore.save(ledger)
        try f.runtime.update { $0.layout = layout }
        try f.runtime.closeTerminalPane(pane.id)
        let saved = try XCTUnwrap(f.runtime.closedTerminalPaneSnapshot(pane.id))
        XCTAssertEqual(saved.archiveID, snapshot.archiveID)
        XCTAssertEqual(saved.processWitnesses, snapshot.processWitnesses)
        XCTAssertEqual(saved.phase, .closed)
    }

    func testFailureAfterPublishingCloseRestoresLivePaneEligibility() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        var validations = 0
        XCTAssertThrowsError(try f.runtime.closeTerminalPane(pane.id, validate: { _ in
            validations += 1
            if validations == 3 { throw TerminalError.invalid("Fixture interrupted before stop") }
        }))
        XCTAssertEqual(validations, 3)
        XCTAssertFalse(try f.runtime.isTerminalIntentionallyClosed(pane.id))
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertFalse(try f.commands().contains("kill "))
    }

    func testUnknownOriginalShellCancelsCloseWithoutChangingLayout() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let layout = try f.runtime.state().layout
        var ledger = try f.runtime.closedTerminalStore.ledger()
        ledger.shells.removeValue(forKey: pane.id)
        try f.runtime.closedTerminalStore.save(ledger)
        try Data("/usr/bin/python3 job.py".utf8).write(to: f.root.appendingPathComponent(pane.id + ".command"))
        XCTAssertThrowsError(try f.runtime.closeTerminalPane(pane.id))
        XCTAssertEqual(try f.runtime.state().layout, layout)
        XCTAssertFalse(try f.commands().contains("kill "))
    }

    func testMultiPaneRestoreFailureKeepsSuccessfulShellAndRetriesOnlyMissingPane() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let first = try f.addPane(), second = try f.addPane(split: true)
        try f.runtime.performAction(.closeTab)
        let failure = f.root.appendingPathComponent("fail-create-" + second.id)
        try Data().write(to: failure)
        XCTAssertThrowsError(try f.runtime.restoreClosedTerminal())
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first(where: { $0.id == first.id })).alive)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first(where: { $0.id == second.id })).alive)
        XCTAssertEqual(try f.runtime.closedTerminalPaneSnapshot(first.id)?.phase, .reopened)
        try FileManager.default.removeItem(at: failure)
        try f.runtime.restoreClosedTerminal()
        XCTAssertEqual(try f.runtime.state().layout.tabs.flatMap(\.panes), [first.id, second.id])
        XCTAssertTrue(try f.runtime.state().layout.closedTabs.isEmpty)
        XCTAssertEqual(try f.runtime.list().filter(\.alive).count, 2)
        XCTAssertEqual(try f.commands().components(separatedBy: "create ").count - 1, 5)
    }

    func testPruningDetachedReopenedArchiveDoesNotRetireItsLiveShell() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        try f.runtime.closeTerminalPane(pane.id)
        try f.runtime.restoreClosedTerminal()
        let snapshot = try XCTUnwrap(f.runtime.closedTerminalPaneSnapshot(pane.id))
        _ = try f.runtime.closedTerminalStore.screenFile(id: snapshot.archiveID)
        try f.runtime.update { $0.layout.detach(pane.id) }
        try f.runtime.pruneClosedTerminalArchives()
        XCTAssertNil(try f.runtime.closedTerminalPaneSnapshot(pane.id))
        XCTAssertNil(try f.runtime.closedTerminalStore.read(snapshot.archiveID + ".json"))
        XCTAssertNil(try f.runtime.closedTerminalStore.read(snapshot.archiveID + ".screen"))
        XCTAssertFalse(try f.runtime.isTerminalIntentionallyClosed(pane.id))
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
    }

    func testRemotePreparedSnapshotIsCancelledWhenLaterPaneCaptureFails() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let transport = try ClosedRemoteCoordinatorFixture(f: f, pane: pane)
        _ = try f.addPane(split: true)
        try Data().write(to: f.root.appendingPathComponent("fail-capture"))
        XCTAssertThrowsError(try f.runtime.performAction(.closeTab))
        XCTAssertTrue(transport.methods.contains("close.cancel"))
        XCTAssertFalse(transport.methods.contains("close.commit"))
        XCTAssertFalse(try f.commands().contains("kill "))
        XCTAssertFalse(try f.runtime.isTerminalIntentionallyClosed(pane.id))
    }

    func testAcknowledgedRemoteCloseIsRecoverableAfterLocalValidationFailure() throws {
        let f = try ClosedMuxFixture(); defer { f.cleanup() }
        let pane = try f.addPane()
        let transport = try ClosedRemoteCoordinatorFixture(f: f, pane: pane)
        var validations = 0
        XCTAssertThrowsError(try f.runtime.closeTerminalPane(pane.id, validate: { _ in
            validations += 1
            if validations == 4 { throw TerminalError.invalid("Fixture interrupted after remote commit") }
        }))
        XCTAssertEqual(transport.methods.filter { $0 == "close.commit" }.count, 1)
        XCTAssertEqual(try f.runtime.closedTerminalPaneSnapshot(pane.id)?.phase, .closed)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first).alive)
        try f.runtime.restoreClosedTerminal()
        XCTAssertTrue(try XCTUnwrap(f.runtime.list().first).alive)
        XCTAssertEqual(transport.methods.filter { $0 == "close.reopen" }.count, 1)
        XCTAssertEqual(try f.runtime.state().layout.focusedPaneID, pane.id)
    }

    func testScreenKeepsColorsAndKoreanButRemovesTerminalSideEffects() {
        let text = "\u{1b}[31m빨강\u{1b}[0m\u{1b}]52;c;secret\u{7}ok\u{1b}[2J\u{1b}Ppayload\u{1b}\\end"
        let safe = ClosedTerminalScreen.sanitized(text)
        XCTAssertTrue(safe.contains("\u{1b}[31m빨강\u{1b}[0m"))
        XCTAssertTrue(safe.contains("okend"))
        XCTAssertFalse(safe.contains("secret")); XCTAssertFalse(safe.contains("payload")); XCTAssertFalse(safe.contains("[2J"))
        XCTAssertLessThanOrEqual(ClosedTerminalScreen.sanitized(String(repeating: "한글\n", count: 30_000)).utf8.count, ScrollbackStore.maximumBytes)
    }

}

/// File-backed fake pane host: `<id>.live` marks a running pane, `commands` logs every backend operation in order,
/// and `fail-*` marker files inject failures. Never starts a real job.
final class ClosedMuxBackend: PaneBackend, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    var socketPath: String { root.appendingPathComponent("fake-pty.sock").path }
    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
    private func read(_ name: String) -> String { (try? String(contentsOf: file(name), encoding: .utf8)) ?? "" }
    private func log(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file("commands").path) {
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } else { try data.write(to: file("commands")) }
    }

    func isRunning() -> Bool { true }
    func create(id: String, argv: [String], environment: [String], cwd: String, cols: Int, rows: Int) throws -> Int32 {
        try log((["create", id] + argv).joined(separator: " "))
        guard !exists("fail-create"), !exists("fail-create-" + id) else { throw TerminalError.runtime("synthetic create failure") }
        let archive = environment.last { $0.hasPrefix("TRANO_REOPEN_ARCHIVE=") }.map { String($0.dropFirst(21)) } ?? ""
        try Data(cwd.utf8).write(to: file(id + ".cwd"))
        try Data((argv.joined(separator: " ") + "\n").utf8).write(to: file(id + ".command"))
        try Data(archive.utf8).write(to: file(id + ".archive"))
        try Data("900001".utf8).write(to: file(id + ".live"))
        return 900001
    }
    func respawn(id: String, argv: [String], environment: [String]?, cwd: String?) throws -> Int32 {
        try log("respawn " + id); throw TerminalError.runtime("Fake pane backend refuses to respawn")
    }
    func list() throws -> [PaneHostPane] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".live") }.sorted().map { name in
            let id = String(name.dropLast(5))
            return PaneHostPane(id: id, pid: 900001, alive: true, exitStatus: nil, title: nil, created: 0, tty: "/dev/ttys999",
                                pipe: false, options: [:], argv: read(id + ".command").trimmingCharacters(in: .newlines)
                                    .split(separator: " ").map(String.init), generation: "fixture-generation")
        }
    }
    func write(_ id: String, _ data: Data) throws { try log("write " + id) }
    func capture(_ id: String, lines: Int, escapes: Bool) throws -> String {
        try log("capture " + id)
        guard !exists("fail-capture") else { throw TerminalError.runtime("capture failed") }
        return "saved output 한글\n"
    }
    func workingDirectory(_ id: String) throws -> String { read(id + ".cwd") }
    func kill(_ id: String) throws {
        try log("kill " + id)
        guard !exists("fail-kill-" + id) else { throw TerminalError.runtime("kill failed") }
        try? FileManager.default.removeItem(at: file(id + ".live"))
    }
    func pipe(_ id: String, command: String) throws { try log("pipe " + id) }
    func setOption(_ id: String, key: String, value: String) throws { try log("option " + id) }
    func environment(_ id: String, key: String) throws -> String? {
        key == "TRANO_REOPEN_ARCHIVE" ? read(id + ".archive") : nil
    }
    func attachArguments(_ id: String) -> [String] { ["pty-attach", id] }
}

final class ClosedMuxFixture {
    let root: URL
    let runtime: TerminalRuntime
    init() throws {
        root = URL(fileURLWithPath: "/tmp/t-close-" + UUID().uuidString.prefix(8))
        runtime = try TerminalRuntime(root: root)
        runtime.host = ClosedMuxBackend(root: root)
        try runtime.update { $0.layout.addWorkspace(title: "closed-fixture") }
    }
    func addPane(shell: String = "/bin/zsh", arguments: [String] = ["-l"], split: Bool = false) throws -> TerminalSession {
        let pane = try runtime.create(title: "Fixture", cwd: root.path, shell: shell, arguments: arguments)
        try runtime.update { state in
            if split, let tab = state.layout.selectedTabID {
                try state.layout.split(tabID: tab, paneID: pane.id, axis: .horizontal)
            } else { state.layout.addTab(paneID: pane.id) }
        }
        return pane
    }
    func commands() throws -> String { try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class ClosedRemoteCoordinatorFixture: ClosedRemoteTerminalTransport {
    var methods: [String] = []
    var tokens: [String: RemoteClosedTerminal] = [:]
    var remote: TerminalSession

    init(f: ClosedMuxFixture, pane: TerminalSession) throws {
        let host = try f.runtime.addRemoteHost(name: "Fixture", address: "fixture.invalid")
        remote = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote fixture", cwd: "/fixture", pid: 900032)
        remote.inputBackendIdentity = "fixture-generation"
        try f.runtime.update { state in
            let index = try XCTUnwrap(state.sessions.firstIndex(where: { $0.id == pane.id }))
            state.sessions[index].remote = .init(hostID: host.id, sessionID: remote.id)
        }
        f.runtime.closedRemoteTransport = self
    }

    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse {
        methods.append(request.method)
        func response(_ value: some Encodable) throws -> APIResponse {
            APIResponse(result: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)))
        }
        if request.method == "server.info" { return APIResponse(result: .object(["closedTerminalProtocol": .number(1)])) }
        if request.method == "sessions.list" { return try response([remote]) }
        let operation = try XCTUnwrap(request.params["operationID"]?.text)
        var token = tokens[operation] ?? RemoteClosedTerminal(closeProtocol: 1, operationID: operation,
            sessionID: remote.id, expectedPID: remote.pid, generation: "fixture-generation", phase: "prepared", historyProvenance: "unavailable")
        switch request.method {
        case "close.prepare", "close.status": break
        case "close.commit": token.phase = "closed"
        case "close.cancel": token.phase = "cancelled"
        case "close.reopen": token.phase = "reopened"; remote.pid = 900033
        default: throw TerminalError.invalid("Unexpected fixture method")
        }
        tokens[operation] = token
        if token.phase == "reopened" {
            guard case .object(var body) = try XCTUnwrap(response(token).result) else { throw TerminalError.invalid("Invalid fixture token") }
            body["session"] = try response(remote).result
            return APIResponse(result: .object(body))
        }
        return try response(token)
    }
}
