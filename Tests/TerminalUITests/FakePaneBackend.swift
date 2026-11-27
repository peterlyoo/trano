import Foundation
import XCTest
@testable import TerminalCore

/// In-memory pane backend for fixtures that must never start real jobs. Every call is recorded; `create` and
/// `respawn` fail unless `allowSpawn` is set, so a fixture that accidentally starts work fails loudly.
final class FakePaneBackend: PaneBackend, @unchecked Sendable {
    let socketPath: String
    private let lock = NSLock()
    private var storedPanes: [PaneHostPane] = []
    private var storedCalls: [String] = []
    /// When set, `create` succeeds without starting anything and returns `spawnPID`; the pane is listed only when
    /// `listSpawned` is set (the old fake tmux printed a PID but never listed the session).
    var allowSpawn = false
    var spawnPID: Int32 = 0
    var listSpawned = false
    var workingDirectoryPath = "/"
    var listHook: (() throws -> Void)?
    var listOverride: (() throws -> [PaneHostPane])?
    var writeHook: ((String, Data) throws -> Void)?

    init(socketPath: String = "/nonexistent/trano-fake-pty.sock", panes: [PaneHostPane] = []) {
        self.socketPath = socketPath
        storedPanes = panes
    }

    var calls: [String] { lock.withLock { storedCalls } }
    var panes: [PaneHostPane] {
        get { lock.withLock { storedPanes } }
        set { lock.withLock { storedPanes = newValue } }
    }

    private func record(_ call: String) { lock.withLock { storedCalls.append(call) } }

    func isRunning() -> Bool { record("isRunning"); return !panes.isEmpty }

    func create(id: String, argv: [String], environment: [String], cwd: String, cols: Int, rows: Int) throws -> Int32 {
        record("create " + id)
        guard allowSpawn else { throw TerminalError.runtime("Fake pane backend refuses to start jobs") }
        if listSpawned { panes.append(Self.pane(id: id, pid: spawnPID, argv: argv)) }
        return spawnPID
    }

    func respawn(id: String, argv: [String], environment: [String]?, cwd: String?) throws -> Int32 {
        record("respawn " + id)
        throw TerminalError.runtime("Fake pane backend refuses to start jobs")
    }

    func list() throws -> [PaneHostPane] {
        record("list")
        try listHook?()
        if let listOverride { return try listOverride() }
        return panes
    }

    func write(_ id: String, _ data: Data) throws { record("write " + id); try writeHook?(id, data) }
    func capture(_ id: String, lines: Int, escapes: Bool) throws -> String { record("capture " + id); return "" }
    func workingDirectory(_ id: String) throws -> String { record("cwd " + id); return workingDirectoryPath }
    func kill(_ id: String) throws { record("kill " + id); lock.withLock { storedPanes.removeAll { $0.id == id } } }
    func pipe(_ id: String, command: String) throws { record("pipe " + id) }
    func setOption(_ id: String, key: String, value: String) throws { record("option " + id + " " + key) }
    func environment(_ id: String, key: String) throws -> String? { record("env " + id + " " + key); return nil }
    func attachArguments(_ id: String) -> [String] { ["pty-attach", id] }

    static func pane(id: String, pid: Int32, alive: Bool = true, title: String? = nil, generation: String? = "fake-generation", argv: [String] = []) -> PaneHostPane {
        PaneHostPane(id: id, pid: pid, alive: alive, exitStatus: alive ? nil : 0, title: title, created: Date().timeIntervalSince1970,
                     tty: "/dev/ttys999", pipe: false, options: [:], argv: argv, generation: generation)
    }
}

extension TerminalRuntime {
    /// Stops this fixture's own PTY host. Never touches another runtime root.
    func shutdownTestHost() {
        try? (host as? PaneHostClient)?.shutdown()
    }

    /// Replaces the old `tmux set-environment -g HOME/ZDOTDIR` fixture step.
    func isolatePaneHome(_ root: URL) {
        paneEnvironmentOverlay = ["HOME=" + root.path, "ZDOTDIR=" + root.path]
    }

    /// Replaces arbitrary `tmux set-environment -g KEY VALUE` fixture steps for panes created afterwards.
    func setPaneEnvironment(_ values: [(String, String)]) {
        paneEnvironmentOverlay += values.map { $0.0 + "=" + $0.1 }
    }

    func hostPane(_ id: String) throws -> PaneHostPane? { try host.pane(id) }

    /// Kills a hosted pane's child with SIGKILL and waits until the host reports it dead (tmux `kill-pane` with
    /// remain-on-exit, or an unexpected process exit).
    func killPaneProcess(_ id: String, timeout: TimeInterval = 5) throws {
        let pane = try XCTUnwrap(try host.pane(id))
        _ = Darwin.kill(pane.pid, SIGKILL)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try host.pane(id)?.alive != true { return }
            usleep(20_000)
        }
        XCTFail("Pane \(id) did not report exit")
    }

    /// Writes an OSC 2 title to the pane's terminal device, as a program running in the pane would.
    func setPaneTitleThroughTTY(_ id: String, _ title: String) throws {
        let tty = try XCTUnwrap(try host.pane(id)?.tty)
        let fd = open(tty, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot open \(tty)") }
        defer { close(fd) }
        let bytes = Array(("\u{1b}]2;" + title + "\u{7}").utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, bytes.count)
    }

    func waitForPaneTitle(_ id: String, timeout: TimeInterval = 5, _ predicate: (String?) -> Bool) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var title: String?
        repeat {
            title = try host.pane(id)?.title
            if predicate(title) { return title }
            usleep(20_000)
        } while Date() < deadline
        return title
    }
}

extension TerminalRuntime {
    /// Simulates a crashed terminal host (the old `tmux kill-server`): SIGKILL the host and wait until it is gone.
    func crashTestHost(timeout: TimeInterval = 5) throws {
        let client = try XCTUnwrap(host as? PaneHostClient)
        let pid = try XCTUnwrap(client.processIdentifier())
        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, Darwin.kill(pid, 0) == 0 || client.isRunning() { usleep(20_000) }
        XCTAssertFalse(client.isRunning())
    }
}

extension TerminalRuntime {
    /// `trano pty-attach` locates the host through TRANO_DATA_DIR; without it the client would look at the default
    /// user runtime. Mirrors the environment TranoView builds for production attaches.
    func testAttachEnvironment(_ id: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TRANO_SESSION"] = id
        environment["TRANO_DATA_DIR"] = root.path
        return environment.map { $0.key + "=" + $0.value }
    }
}
