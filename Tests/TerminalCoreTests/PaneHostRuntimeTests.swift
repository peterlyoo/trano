import Darwin
import Foundation
import XCTest
@testable import TerminalCore

/// Real PTY host coverage in short, isolated `/tmp/trph-*` roots. Every test shuts its own host down.
final class PaneHostRuntimeTests: XCTestCase {
    private var root: URL!
    private var runtime: TerminalRuntime!
    private var legacyTmuxStarted = false

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/trph-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased())
        runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
    }

    override func tearDownWithError() throws {
        if legacyTmuxStarted, let tmux = runtime.legacyTmuxExecutable, FileManager.default.fileExists(atPath: runtime.legacySocketPath) {
            _ = try? CommandRunner.run(tmux, ["-S", runtime.legacySocketPath, "kill-server"])
        }
        runtime.shutdownTestHost()
        XCTAssertFalse((runtime.host as? PaneHostClient)?.isRunning() ?? false)
        try? FileManager.default.removeItem(at: root)
    }

    private var client: PaneHostClient { runtime.host as! PaneHostClient }

    private func waitForCapture(_ id: String, timeout: TimeInterval = 5, _ predicate: (String) -> Bool) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        repeat {
            text = try runtime.host.capture(id, lines: 200)
            if predicate(text) { return text }
            usleep(20_000)
        } while Date() < deadline
        return text
    }

    private func newID() -> String { UUID().uuidString.lowercased() }

    // Implements: FR-NAV-1
    func testCreateListWriteCaptureKoreanWithoutNulBytes() throws {
        let id = newID()
        let pid = try runtime.host.create(id: id, argv: ["/bin/cat"], environment: ["LANG=en_US.UTF-8"], cwd: root.path)
        XCTAssertGreaterThan(pid, 1)
        XCTAssertTrue(client.isRunning())
        XCTAssertTrue(FileManager.default.fileExists(atPath: client.socketPath))
        let pane = try XCTUnwrap(try runtime.host.pane(id))
        XCTAssertEqual(pane.pid, pid)
        XCTAssertTrue(pane.alive)
        XCTAssertTrue(pane.tty.hasPrefix("/dev/"))
        XCTAssertEqual(pane.argv, ["/bin/cat"])
        XCTAssertFalse(pane.generation?.isEmpty ?? true)
        XCTAssertEqual(try runtime.host.environment(id, key: "TERM"), "xterm-256color")
        let marker = "한글 입력 확인 NFC é e\u{301}"
        try runtime.host.write(id, Data((marker + "\r").utf8))
        let text = try waitForCapture(id) { $0.contains(marker) }
        XCTAssertTrue(text.contains(marker), text)
        XCTAssertFalse(text.unicodeScalars.contains("\0"))
        XCTAssertFalse(try runtime.host.capture(id, lines: 200, escapes: true).unicodeScalars.contains("\0"))
        XCTAssertEqual(URL(fileURLWithPath: try runtime.host.workingDirectory(id)).resolvingSymlinksInPath().path,
                       root.resolvingSymlinksInPath().path)
    }

    // Implements: FR-NAV-1
    func testRuntimeCreateAppliesEnvironmentOverlay() throws {
        let pane = try runtime.create(title: "Overlay", cwd: root.path, shell: "/bin/sleep", arguments: ["30"])
        XCTAssertEqual(try runtime.host.environment(pane.id, key: "HOME"), root.path)
        XCTAssertEqual(try runtime.host.environment(pane.id, key: "ZDOTDIR"), root.path)
        XCTAssertEqual(try runtime.host.environment(pane.id, key: "TRANO_SESSION"), pane.id)
        XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
    }

    // Implements: FR-NAV-1
    func testAttachClientReportsAWindowChangeThatArrivesWhileItIsStillAttaching() throws {
        let executable = try XCTUnwrap(PaneHostClient.resolveExecutable(client.executable))
        let id = newID()
        _ = try runtime.host.create(id: id, argv: ["/bin/sh"], environment: ["PS1=$ "], cwd: root.path, cols: 80, rows: 24)
        for (attempt, delay) in stride(from: UInt32(0), to: 24_000, by: 2_000).enumerated() {
            var master: Int32 = -1, slave: Int32 = -1
            var initial = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            XCTAssertEqual(openpty(&master, &slave, nil, nil, &initial), 0)
            let slavePath = String(cString: ttyname(slave))
            close(slave)
            defer { close(master) }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            // A session leader that opens the terminal makes it the controlling one, which is what delivers SIGWINCH.
            posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
            posix_spawn_file_actions_adddup2(&actions, 0, 1)
            posix_spawn_file_actions_addclose(&actions, master)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
            let arguments = [executable, "pty-attach", id, "--root", root.path]
            var pid: pid_t = 0
            let cArguments = arguments.map { strdup($0) } + [nil]
            defer { cArguments.forEach { free($0) } }
            XCTAssertEqual(posix_spawn(&pid, executable, &actions, &attributes, cArguments, environ), 0)
            defer { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) }
            usleep(delay)
            let rows = 30 + attempt, columns = 100 + attempt
            var changed = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
            XCTAssertEqual(ioctl(master, TIOCSWINSZ, &changed), 0)
            let expected = "\(rows) \(columns)"
            var size = ""
            let deadline = Date().addingTimeInterval(10)
            repeat {
                try runtime.host.write(id, Data("stty size\r".utf8))
                size = try waitForCapture(id, timeout: 0.3) { $0.contains(expected) }
            } while !size.contains(expected) && Date() < deadline
            XCTAssertTrue(size.contains(expected), "attempt \(attempt) delay \(delay)us expected \(expected)")
        }
    }

    // Implements: FR-NAV-1
    func testAttachResizeAndClientDisconnectLeavesPaneAlive() throws {
        let id = newID()
        _ = try runtime.host.create(id: id, argv: ["/bin/sh"], environment: ["PS1=$ "], cwd: root.path, cols: 80, rows: 24)
        let fd = try UnixSocket.make()
        defer { close(fd) }
        XCTAssertEqual(try UnixSocket.address(client.socketPath) { Darwin.connect(fd, $0, $1) }, 0)
        let request: [String: Any] = ["op": "attach", "id": id, "cols": 80, "rows": 24, "version": PaneHostClient.protocolVersion]
        try UnixSocket.sendLine(JSONSerialization.data(withJSONObject: request), fd: fd)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: PaneHostClient.receive(fd: fd)) as? [String: Any])
        XCTAssertNil(reply["error"])
        let frame = PaneHostFrame.encode(PaneHostFrame.resize, PaneHostFrame.resizePayload(cols: 123, rows: 41))
        XCTAssertEqual(frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, frame.count)
        var size = ""
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try runtime.host.write(id, Data("stty size\r".utf8))
            size = try waitForCapture(id, timeout: 0.5) { $0.contains("41 123") }
        } while !size.contains("41 123") && Date() < deadline
        XCTAssertTrue(size.contains("41 123"), size)
        close(fd)
        usleep(200_000)
        let pane = try XCTUnwrap(try runtime.host.pane(id))
        XCTAssertTrue(pane.alive)
        try runtime.host.write(id, Data("echo still-here\r".utf8))
        XCTAssertTrue(try waitForCapture(id) { $0.contains("still-here") }.contains("still-here"))
    }

    // Implements: FR-NAV-1, FR-CLOSE-1
    func testKillRemovesPaneAndDeadPaneIsKeptUntilKilled() throws {
        let dead = newID(), killed = newID()
        let deadPID = try runtime.host.create(id: dead, argv: ["/bin/sh", "-c", "exit 7"], environment: [], cwd: root.path)
        _ = try runtime.host.create(id: killed, argv: ["/bin/sleep", "30"], environment: [], cwd: root.path)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, try runtime.host.pane(dead)?.alive == true { usleep(20_000) }
        let exited = try XCTUnwrap(try runtime.host.pane(dead))
        XCTAssertFalse(exited.alive)
        XCTAssertEqual(exited.pid, deadPID)
        XCTAssertEqual(exited.exitStatus, 7)
        XCTAssertThrowsError(try runtime.host.write(dead, Data("x".utf8)))
        let killedPID = try XCTUnwrap(try runtime.host.pane(killed)).pid
        try runtime.host.kill(killed)
        XCTAssertNil(try runtime.host.pane(killed))
        XCTAssertFalse(TerminalRuntime.processExists(killedPID))
        XCTAssertNotNil(try runtime.host.pane(dead))
        try runtime.host.kill(dead)
        XCTAssertNil(try runtime.host.pane(dead))
    }

    // Implements: FR-LOAD-1, FR-LOAD-2
    func testSessionLoadTokenComesFromRealPaneGeneration() throws {
        let pane = try runtime.create(title: "Token", cwd: root.path, shell: "/bin/sleep", arguments: ["30"])
        let hosted = try XCTUnwrap(try runtime.host.pane(pane.id))
        let generation = try XCTUnwrap(hosted.generation)
        let target = try XCTUnwrap(try runtime.sessionLoadTargets().first { $0.paneID == pane.id })
        XCTAssertEqual(target.ownershipToken, "pty:" + generation + ":" + String(hosted.pid) + ":agent:shell")
        XCTAssertEqual(target.backendPID, hosted.pid)
        XCTAssertTrue(target.alive)
        try runtime.host.kill(pane.id)
        let recreated = try runtime.create(title: "Token", cwd: root.path, shell: "/bin/sleep", arguments: ["30"], restoringID: pane.id)
        let next = try XCTUnwrap(try runtime.sessionLoadTargets().first { $0.paneID == pane.id })
        XCTAssertEqual(recreated.id, pane.id)
        XCTAssertNotEqual(next.ownershipToken, target.ownershipToken)
    }

    // Implements: FR-RECOVERY-2
    func testLegacyTmuxPaneMigratesToHostWithSameID() throws {
        guard let tmux = runtime.legacyTmuxExecutable else {
            throw XCTSkip("tmux is not installed")
        }
        let id = newID()
        try runtime.update { state in
            state.settings.automaticRestore = true
            state.sessions = [TerminalSession(id: id, title: "Legacy", cwd: root.path, pid: 0)]
            state.layout.addWorkspace(title: "Legacy")
            state.layout.addTab(paneID: id)
        }
        legacyTmuxStarted = true
        let started = try CommandRunner.run(tmux, ["-u", "-f", "/dev/null", "-S", runtime.legacySocketPath,
                                                   "new-session", "-d", "-s", id, "-c", root.path, "--", "/bin/sleep", "120"])
        XCTAssertEqual(started.status, 0, String(decoding: started.stderr, as: UTF8.self))
        let legacy = try runtime.legacyTmuxPanes()
        XCTAssertEqual(legacy.map(\.id), [id])
        let legacyPID = try XCTUnwrap(legacy.first?.pid)
        XCTAssertTrue(TerminalRuntime.processExists(legacyPID))

        let result = try runtime.migrateLegacyTmuxPanes()
        XCTAssertEqual(result.migrated, [id])
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertFalse(TerminalRuntime.processExists(legacyPID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.legacySocketPath))
        let hosted = try XCTUnwrap(try runtime.host.pane(id))
        XCTAssertTrue(hosted.alive)
        XCTAssertNotEqual(hosted.pid, legacyPID)
        let session = try XCTUnwrap(try runtime.list().first { $0.id == id })
        XCTAssertTrue(session.alive)
        XCTAssertEqual(session.pid, hosted.pid)
        XCTAssertTrue(try runtime.migrateLegacyTmuxPanes().migrated.isEmpty)
    }

    // Implements: FR-RECOVERY-2
    func testLegacyParserRejectsMalformedAndDuplicateRows() {
        let id = newID()
        let rows = TerminalRuntime.parseLegacyTmuxPanes("\(id)|123|0\n\(id)|124|0\nnot-a-uuid|5|0\n\(newID())|1|0\n\(newID())|9|2\n")
        XCTAssertEqual(rows, [TerminalRuntime.LegacyTmuxPane(id: id, pid: 123, alive: true)])
    }
}
