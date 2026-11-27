import Foundation
import Darwin
import SwiftTerm
import TerminalCore

let hostQueue = DispatchQueue(label: "trano.pty-host")

final class HostedPane: TerminalDelegate {
    let id: String
    var pid: pid_t = 0
    var master: Int32 = -1
    var terminal: Terminal!
    var alive = false
    var exitStatus: Int32?
    var title: String?
    let created = Date().timeIntervalSince1970
    var tty = ""
    var argv: [String] = []
    var environment: [String] = []
    var options: [String: String] = [:]
    var readSource: DispatchSourceRead?
    var exitSource: DispatchSourceProcess?
    var input = OutboundBuffer()
    var pipe: PipeTap?
    var clients: [AttachedClient] = []
    var spawnSerial = 0

    init(id: String, cols: Int, rows: Int) {
        self.id = id
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 10_000))
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard clients.isEmpty, alive else { return }
        enqueue(Array(data))
    }

    func setTerminalTitle(source: Terminal, title: String) { self.title = title }

    func enqueue(_ bytes: [UInt8]) {
        guard master >= 0, !bytes.isEmpty else { return }
        // The PTY input queue holds about 1 KiB, so a paste leaves a remainder that only this handler ever writes.
        let descriptor = master
        _ = input.append(bytes, fd: descriptor, queue: hostQueue, onWritable: { [weak self] in
            guard let self, self.master == descriptor else { return }
            if !self.input.flush(fd: descriptor) { self.input.cancel() }
        })
    }

    func spawn(argv: [String], environment: [String], cwd: String?) throws {
        guard let requested = argv.first, let executable = PtyHost.resolve(requested, environment: environment) else {
            throw TerminalError.invalid("Cannot find command " + (argv.first ?? ""))
        }
        var size = winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: 0, ws_ypixel: 0)
        guard let child = PseudoTerminalHelpers.fork(andExec: executable, args: argv, env: environment, currentDirectory: cwd, desiredWindowSize: &size) else {
            throw TerminalError.runtime("Cannot start \(executable)")
        }
        pid = child.pid; master = child.masterFd
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        tty = ptsname(master).map { String(cString: $0) } ?? ""
        alive = true; exitStatus = nil; spawnSerial += 1
        self.argv = argv; self.environment = environment
        input = OutboundBuffer()
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: hostQueue)
        let fd = master
        read.setEventHandler { [weak self] in self?.drain() }
        read.setCancelHandler { close(fd) }
        read.resume(); readSource = read
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: hostQueue)
        let childPID = pid
        exit.setEventHandler { [weak self] in self?.reap(childPID) }
        exit.resume(); exitSource = exit
    }

    func drain() {
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(master, &bytes, bytes.count)
            if count > 0 {
                let chunk = Array(bytes.prefix(count))
                terminal.feed(byteArray: chunk)
                for client in clients { client.write(chunk) }
                pipe?.write(chunk)
                if count < bytes.count { return }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return }
            closeMaster()
            collectExit()
            return
        }
    }

    // The PTY usually reports EOF before the process-exit event; the exit source must outlive the master.
    func closeMaster() {
        readSource?.cancel(); readSource = nil
        input.cancel()
        master = -1
    }

    func reap(_ childPID: pid_t) {
        guard childPID == pid else { return }
        drain()
        collectExit()
    }

    func collectExit() {
        guard alive, pid > 1 else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        alive = false
        exitSource?.cancel(); exitSource = nil
        closeMaster()
        terminal.terminalLock.withLock { terminal.programStatusProcessExited() }
        for client in clients { client.finish() }
        clients.removeAll()
    }

    func terminate(waitForExit: Bool) {
        let child = pid
        exitSource?.cancel(); exitSource = nil
        if alive, child > 1 {
            _ = killpg(child, SIGHUP); _ = Darwin.kill(child, SIGHUP)
        }
        if waitForExit, child > 1 {
            // The read source closes the master only after this queue is free again. Until then nothing reads the
            // PTY, and a session leader cannot finish exiting while its TTY output is undrained, so discard that
            // output here and never wait without a bound: an unbounded wait deadlocks every pane on this host.
            let descriptor = master
            var status: Int32 = 0
            var reaped = false
            func exited() -> Bool {
                Self.discardOutput(descriptor)
                if waitpid(child, &status, WNOHANG) == child { reaped = true; return true }
                return Darwin.kill(child, 0) != 0 && errno == ESRCH
            }
            var gone = false
            for _ in 0..<100 where !gone { gone = exited(); if !gone { usleep(20_000) } }
            if !gone {
                _ = killpg(child, SIGKILL); _ = Darwin.kill(child, SIGKILL)
                for _ in 0..<100 where !gone { gone = exited(); if !gone { usleep(20_000) } }
            }
            closeMaster()
            if !gone && !reaped {
                DispatchQueue.global(qos: .utility).async { var late: Int32 = 0; _ = waitpid(child, &late, 0) }
            }
        } else { closeMaster() }
        alive = false
    }

    private static func discardOutput(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        // Bounded so a child that keeps writing cannot hold the host queue here.
        for _ in 0..<64 {
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 || (count < 0 && errno == EINTR) { continue }
            return
        }
    }

    func resize(cols: Int, rows: Int) {
        guard (2...1000).contains(cols), (1...1000).contains(rows), cols != terminal.cols || rows != terminal.rows else { return }
        terminal.resize(cols: cols, rows: rows)
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: master, windowSize: &size)
    }

    var record: [String: Any] {
        var value: [String: Any] = ["id": id, "pid": Int(pid), "alive": alive, "created": created, "tty": tty,
                                    "pipe": pipe?.isOpen == true, "options": options, "argv": argv,
                                    "generation": "\(getpid()):\(Int(created * 1000)):\(spawnSerial)"]
        if let exitStatus { value["exitStatus"] = Int(exitStatus) }
        if let title { value["title"] = title }
        return value
    }

    func workingDirectory() -> String? {
        var candidates: [pid_t] = []
        if master >= 0 { let group = tcgetpgrp(master); if group > 1 { candidates.append(group) } }
        candidates.append(pid)
        for candidate in candidates {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(candidate, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
                let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if path.hasPrefix("/") { return path }
            }
        }
        return nil
    }
}

struct OutboundBuffer {
    private var pending: [UInt8] = []
    private var source: DispatchSourceWrite?
    var limit = 32 << 20

    var count: Int { pending.count }

    mutating func cancel() { source?.cancel(); source = nil; pending.removeAll() }

    @discardableResult mutating func append(_ bytes: [UInt8], fd: Int32, queue: DispatchQueue) -> Bool {
        if pending.isEmpty {
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && errno == EAGAIN { break }
                return false
            }
            if offset == bytes.count { return true }
            pending.append(contentsOf: bytes[offset...])
        } else {
            guard pending.count + bytes.count <= limit else { return false }
            pending.append(contentsOf: bytes)
        }
        if source == nil {
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source = write
            write.resume()
        }
        return true
    }

    mutating func flush(fd: Int32) -> Bool {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if written > 0 { pending.removeFirst(written); continue }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && errno == EAGAIN { return true }
            return false
        }
        source?.cancel(); source = nil
        return true
    }

    mutating func setHandler(_ handler: @escaping () -> Void) { source?.setEventHandler(handler: handler) }
}

extension OutboundBuffer {
    mutating func append(_ bytes: [UInt8], fd: Int32, queue: DispatchQueue, onWritable: @escaping () -> Void) -> Bool {
        let ok = append(bytes, fd: fd, queue: queue)
        setHandler(onWritable)
        return ok
    }
}

final class PipeTap {
    let fd: Int32
    let pid: pid_t
    var buffer = OutboundBuffer()
    var isOpen = true

    init(command: String, environment: [String]) throws {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw TerminalError.runtime("Cannot create pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[0], 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ["/bin/sh", "-c", command]
        var child: pid_t = 0
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, cArgs, cEnv)
        Darwin.close(fds[0])
        guard status == 0 else { Darwin.close(fds[1]); throw TerminalError.runtime("Cannot start pipe command") }
        fd = fds[1]; pid = child
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        DispatchQueue.global(qos: .utility).async { var s: Int32 = 0; _ = waitpid(child, &s, 0) }
    }

    func write(_ bytes: [UInt8]) {
        guard isOpen else { return }
        let descriptor = fd
        if !buffer.append(bytes, fd: descriptor, queue: hostQueue, onWritable: { [weak self] in
            guard let self, self.isOpen else { return }
            if !self.buffer.flush(fd: descriptor) { self.close() }
        }) { close() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        buffer.cancel()
        Darwin.close(fd)
    }
}

final class AttachedClient {
    let fd: Int32
    weak var pane: HostedPane?
    var buffer = OutboundBuffer()
    var readSource: DispatchSourceRead?
    var frames: [UInt8] = []
    var closed = false
    let onClose: (AttachedClient) -> Void

    init(fd: Int32, pane: HostedPane, onClose: @escaping (AttachedClient) -> Void) {
        self.fd = fd; self.pane = pane; self.onClose = onClose
        buffer.limit = 64 << 20
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: hostQueue)
        read.setEventHandler { [weak self] in self?.receive() }
        read.setCancelHandler { Darwin.close(fd) }
        read.resume(); readSource = read
    }

    func write(_ bytes: [UInt8]) {
        guard !closed else { return }
        let descriptor = fd
        if !buffer.append(bytes, fd: descriptor, queue: hostQueue, onWritable: { [weak self] in
            guard let self, !self.closed else { return }
            if !self.buffer.flush(fd: descriptor) { self.finish() }
        }) { finish() }
    }

    func receive() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard count > 0 else { finish(); return }
        frames.append(contentsOf: bytes.prefix(count))
        process()
    }

    func process() {
        while frames.count >= 5 {
            let length = Int(frames[1]) << 24 | Int(frames[2]) << 16 | Int(frames[3]) << 8 | Int(frames[4])
            guard length <= 1 << 20 else { finish(); return }
            guard frames.count >= 5 + length else { break }
            let payload = Array(frames[5..<5 + length])
            let type = frames[0]
            frames.removeFirst(5 + length)
            guard let pane else { continue }
            if type == PaneHostFrame.input { pane.enqueue(payload) }
            else if type == PaneHostFrame.resize, payload.count == 4 {
                pane.resize(cols: Int(payload[0]) << 8 | Int(payload[1]), rows: Int(payload[2]) << 8 | Int(payload[3]))
            }
        }
    }

    func finish() {
        guard !closed else { return }
        closed = true
        let descriptor = fd
        _ = buffer.flush(fd: descriptor)
        buffer.cancel()
        readSource?.cancel(); readSource = nil
        onClose(self)
    }
}

final class RequestOwnership { var handedOff = false }

final class PtyHost {
    let root: URL
    var panes: [String: HostedPane] = [:]
    var listenFD: Int32 = -1
    var acceptSource: DispatchSourceRead?
    var connections = 0
    var requestSources: [Int32: DispatchSourceRead] = [:]
    var idleSince = Date()

    init(root: URL) { self.root = root }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN); signal(SIGHUP, SIG_IGN)
        let lock = open(root.appendingPathComponent("pty-host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        let path = root.appendingPathComponent("pty.sock").path
        unlink(path)
        do {
            listenFD = try UnixSocket.make()
            let previous = umask(0o077)
            let bound = try UnixSocket.address(path) { bind(listenFD, $0, $1) }
            umask(previous)
            guard bound == 0, listen(listenFD, 64) == 0 else { exit(1) }
        } catch { exit(1) }
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)
        let accept = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: hostQueue)
        accept.setEventHandler { [weak self] in self?.acceptConnections() }
        accept.resume(); acceptSource = accept
        let timer = DispatchSource.makeTimerSource(queue: hostQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.panes.isEmpty && self.connections == 0 {
                if Date().timeIntervalSince(self.idleSince) > 30 { unlink(path); exit(0) }
            } else { self.idleSince = Date() }
        }
        timer.resume()
        withExtendedLifetime((self, timer)) { dispatchMain() }
    }

    func acceptConnections() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            guard UnixSocket.peerUID(fd) == getuid() else { close(fd); continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            connections += 1
            var pending: [UInt8] = []
            let ownership = RequestOwnership()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: hostQueue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, !ownership.handedOff else { return }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = read(fd, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
                guard count > 0 else { source.cancel(); return }
                pending.append(contentsOf: bytes.prefix(count))
                if pending.count > 4 << 20 { source.cancel(); return }
                guard let newline = pending.firstIndex(of: 10) else { return }
                let line = Data(pending[..<newline])
                let rest = Array(pending[(newline + 1)...])
                ownership.handedOff = true
                source.cancel()
                self.requestSources.removeValue(forKey: fd)
                self.handle(line: line, fd: fd, rest: rest)
            }
            source.setCancelHandler { [weak self] in
                guard !ownership.handedOff else { return }
                close(fd)
                self?.connections -= 1
                self?.requestSources.removeValue(forKey: fd)
            }
            requestSources[fd] = source
            source.resume()
        }
    }

    func reply(_ fd: Int32, _ body: [String: Any]) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        data.append(10)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    func handle(line: Data, fd: Int32, rest: [UInt8]) {
        var keep = false
        defer { if !keep { close(fd); connections -= 1 } }
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = request["op"] as? String else {
            reply(fd, ["error": "Invalid request"]); return
        }
        guard (request["version"] as? Int) == PaneHostClient.protocolVersion else {
            reply(fd, ["error": "Terminal host protocol mismatch"]); return
        }
        do {
            if op == "ping" { reply(fd, ["ok": true, "pid": Int(getpid()), "panes": panes.count]); return }
            if op == "shutdown" {
                for pane in panes.values {
                    for client in pane.clients { client.finish() }
                    pane.pipe?.close()
                    pane.terminate(waitForExit: true)
                }
                panes.removeAll()
                reply(fd, ["ok": true])
                unlink(root.appendingPathComponent("pty.sock").path)
                exit(0)
            }
            guard let id = request["id"] as? String, UUID(uuidString: id) != nil else {
                if op == "list" { reply(fd, ["ok": true, "panes": panes.values.sorted { $0.created < $1.created }.map(\.record)]); return }
                throw TerminalError.invalid("Invalid pane ID")
            }
            switch op {
            case "create":
                guard panes[id] == nil else { throw TerminalError.invalid("Pane already exists") }
                let pane = HostedPane(id: id, cols: request["cols"] as? Int ?? 100, rows: request["rows"] as? Int ?? 30)
                try pane.spawn(argv: request["argv"] as? [String] ?? [], environment: Self.environment(overlay: request["env"] as? [String] ?? []), cwd: request["cwd"] as? String)
                panes[id] = pane
                reply(fd, ["ok": true, "pid": Int(pane.pid)])
            case "respawn":
                let pane = try require(id)
                pane.terminate(waitForExit: true)
                let environment = (request["env"] as? [String]).map { Self.environment(overlay: $0) } ?? pane.environment
                try pane.spawn(argv: request["argv"] as? [String] ?? [], environment: environment, cwd: request["cwd"] as? String ?? pane.workingDirectory())
                reply(fd, ["ok": true, "pid": Int(pane.pid)])
            case "write":
                let pane = try require(id)
                guard pane.alive, let encoded = request["data"] as? String, let data = Data(base64Encoded: encoded) else { throw TerminalError.invalid("Pane is not running") }
                pane.enqueue(Array(data))
                reply(fd, ["ok": true])
            case "capture":
                let pane = try require(id)
                let lines = pane.terminal.terminalLock.withLock {
                    pane.terminal.captureLines(history: request["lines"] as? Int ?? 100, escapes: request["escapes"] as? Bool ?? false)
                }
                reply(fd, ["ok": true, "text": lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")])
            case "cwd":
                let pane = try require(id)
                guard let path = pane.workingDirectory() else { throw TerminalError.runtime("Working directory is unavailable") }
                reply(fd, ["ok": true, "cwd": path])
            case "kill":
                if let pane = panes.removeValue(forKey: id) {
                    for client in pane.clients { client.finish() }
                    pane.clients.removeAll()
                    pane.pipe?.close()
                    pane.terminate(waitForExit: true)
                }
                reply(fd, ["ok": true])
            case "pipe":
                let pane = try require(id)
                pane.pipe?.close(); pane.pipe = nil
                if let command = request["command"] as? String, !command.isEmpty {
                    pane.pipe = try PipeTap(command: command, environment: pane.environment)
                }
                reply(fd, ["ok": true])
            case "option":
                let pane = try require(id)
                guard let key = request["key"] as? String, key.utf8.count <= 64 else { throw TerminalError.invalid("Invalid option") }
                if let value = request["value"] as? String { pane.options[key] = value }
                reply(fd, ["ok": true, "value": pane.options[key] ?? NSNull()])
            case "env":
                let pane = try require(id)
                let key = (request["key"] as? String ?? "") + "="
                let value = pane.environment.last { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
                reply(fd, ["ok": true, "value": value ?? NSNull()])
            case "attach":
                let pane = try require(id)
                guard pane.alive else {
                    reply(fd, ["ok": true, "pid": Int(pane.pid), "alive": false])
                    let snapshot = pane.terminal.terminalLock.withLock { pane.terminal.reattachSnapshot(title: pane.title) }
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                    snapshot.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { break }
                        }
                    }
                    return
                }
                pane.resize(cols: request["cols"] as? Int ?? pane.terminal.cols, rows: request["rows"] as? Int ?? pane.terminal.rows)
                reply(fd, ["ok": true, "pid": Int(pane.pid)])
                let snapshot = pane.terminal.terminalLock.withLock { pane.terminal.reattachSnapshot(title: pane.title) }
                let client = AttachedClient(fd: fd, pane: pane) { [weak self, weak pane] client in
                    pane?.clients.removeAll { $0 === client }
                    self?.connections -= 1
                }
                keep = true
                pane.clients.append(client)
                client.write(snapshot)
                if !rest.isEmpty { client.frames = rest; client.process() }
            default:
                throw TerminalError.invalid("Unknown terminal host operation")
            }
        } catch {
            reply(fd, ["error": error.localizedDescription])
        }
    }

    static let scrubbedKeys: Set<String> = ["TMUX", "TMUX_PANE", "REX_BLOCK", "REX_SESSION", "REX_SERVER", "TRANO_LAUNCH_ID", "TRANO_SESSION"]

    static func environment(overlay: [String]) -> [String] {
        var values = ProcessInfo.processInfo.environment.filter { !scrubbedKeys.contains($0.key) }
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        var order = values.keys.sorted()
        for entry in overlay {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            let key = String(entry[..<equals])
            if values[key] == nil { order.append(key) }
            values[key] = String(entry[entry.index(after: equals)...])
        }
        return order.compactMap { key in values[key].map { key + "=" + $0 } }
    }

    static func resolve(_ command: String, environment: [String]) -> String? {
        if command.contains("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        let path = environment.last { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = String(directory) + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func require(_ id: String) throws -> HostedPane {
        guard let pane = panes[id] else { throw TerminalError.invalid("can't find pane: " + id) }
        return pane
    }
}
