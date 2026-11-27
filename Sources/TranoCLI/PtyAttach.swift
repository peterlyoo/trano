import Foundation
import Darwin
import TerminalCore

private var resizeWakeDescriptor: Int32 = -1

enum PtyAttach {
    static func run(id: String, root: URL) -> Int32 {
        guard UUID(uuidString: id) != nil else { return 2 }
        let client = PaneHostClient(root: root, executable: nil)
        guard let fd = try? connect(client) else {
            FileHandle.standardError.write(Data("trano: terminal host is not running\r\n".utf8)); return 1
        }
        // The handler is installed before the size is read, and it wakes the
        // loop through a pipe, so a size change during the handshake or just
        // before poll is never lost.
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else { return 1 }
        for descriptor in wake {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        resizeWakeDescriptor = wake[1]
        signal(SIGWINCH) { _ in var byte: UInt8 = 1; _ = write(resizeWakeDescriptor, &byte, 1) }
        let size = windowSize()
        let request: [String: Any] = ["op": "attach", "id": id, "cols": size.cols, "rows": size.rows, "version": PaneHostClient.protocolVersion]
        guard let body = try? JSONSerialization.data(withJSONObject: request), (try? UnixSocket.sendLine(body, fd: fd)) != nil,
              let line = readLine(fd), let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return 1 }
        if let error = reply["error"] as? String {
            FileHandle.standardError.write(Data(("trano: " + error + "\r\n").utf8)); return 1
        }
        var original = termios()
        let interactive = isatty(0) == 1 && tcgetattr(0, &original) == 0
        if interactive {
            var raw = original
            cfmakeraw(&raw)
            _ = tcsetattr(0, TCSANOW, &raw)
        }
        defer { if interactive { _ = tcsetattr(0, TCSANOW, &original) } }
        signal(SIGPIPE, SIG_IGN)
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var buffer = [UInt8](repeating: 0, count: 65536)
        var stdinOpen = true
        // The window may have changed while the host answered the handshake.
        var resizePending = true
        while true {
            if resizePending {
                resizePending = false
                let size = windowSize()
                guard sendAll(fd, PaneHostFrame.encode(PaneHostFrame.resize, PaneHostFrame.resizePayload(cols: size.cols, rows: size.rows))) else { return 0 }
            }
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            if stdinOpen { fds.append(pollfd(fd: 0, events: Int16(POLLIN), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 { if errno == EINTR { continue }; return 1 }
            if fds[0].revents != 0 {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return 0 }
                guard writeAll(1, Array(buffer.prefix(count))) else { return 0 }
            }
            if fds[1].revents != 0 {
                while read(wake[0], &buffer, buffer.count) > 0 {}
                resizePending = true
            }
            if stdinOpen, fds.count > 2, fds[2].revents != 0 {
                let count = read(0, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { stdinOpen = false; continue }
                guard sendAll(fd, PaneHostFrame.encode(PaneHostFrame.input, Array(buffer.prefix(count)))) else { return 0 }
            }
        }
    }

    private static func connect(_ client: PaneHostClient) throws -> Int32 {
        let fd = try UnixSocket.make()
        guard try UnixSocket.address(client.socketPath, { Darwin.connect(fd, $0, $1) }) == 0 else { close(fd); throw TerminalError.runtime("connect") }
        return fd
    }

    private static func windowSize() -> (cols: Int, rows: Int) {
        var size = winsize()
        for descriptor in [Int32(0), 1] where ioctl(descriptor, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 && size.ws_row > 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (100, 30)
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 1 << 20 {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == 10 { return line }
            line.append(byte)
        }
        return nil
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if written > 0 { offset += written } else if written < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool { writeAll(fd, bytes) }
}
