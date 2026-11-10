import Foundation
import Darwin

struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 5, limit: Int = 1_048_576) throws -> CommandResult {
        let environment = environment ?? ProcessInfo.processInfo.environment
        guard !executable.isEmpty, !executable.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }),
              timeout.isFinite, timeout > 0, limit >= 0 else { throw TerminalError.runtime("Invalid command arguments, environment, or limits") }
        var owned = Set<Int32>()
        defer { for fd in owned { close(fd) } }
        func keep(_ original: Int32) throws -> Int32 {
            guard original >= 0 else { throw TerminalError.runtime("Cannot create command descriptor") }
            let fd: Int32
            if original <= STDERR_FILENO {
                fd = fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
                close(original); owned.remove(original)
                guard fd >= 0 else { throw TerminalError.runtime("Cannot duplicate command descriptor") }
            } else { fd = original }
            owned.insert(fd)
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw TerminalError.runtime("Cannot protect command descriptor") }
            return fd
        }
        func pipePair() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw TerminalError.runtime("Cannot create command pipe") }
            owned.formUnion(pair)
            return (try keep(pair[0]), try keep(pair[1]))
        }
        func closeOwned(_ fd: Int32) { if owned.remove(fd) != nil { close(fd) } }
        func nonblocking(_ fd: Int32) throws {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw TerminalError.runtime("Cannot configure command pipe") }
        }
        let output = try pipePair(), errors = try pipePair()
        let incoming = input == nil ? nil : try pipePair()
        let inputFD = try incoming?.0 ?? keep(open("/dev/null", O_RDONLY | O_CLOEXEC))
        let readFDs = [output.0, errors.0]
        for fd in readFDs { try nonblocking(fd) }
        if let incoming {
            try nonblocking(incoming.1)
            guard fcntl(incoming.1, F_SETNOSIGPIPE, 1) == 0 else { throw TerminalError.runtime("Cannot protect command input") }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw TerminalError.runtime("Cannot prepare command descriptors") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw TerminalError.runtime("Cannot prepare command attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        for (from, to) in [(inputFD, STDIN_FILENO), (output.1, STDOUT_FILENO), (errors.1, STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, from, to) == 0 else { throw TerminalError.runtime("Cannot prepare command stream") }
        }
        for fd in owned {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw TerminalError.runtime("Cannot close child descriptors") }
        }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGINT, SIGTERM, SIGPIPE] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0 else {
            throw TerminalError.runtime("Cannot configure child signals")
        }
        let path = URL(fileURLWithPath: executable).path
        var argv = ([path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw TerminalError.runtime("Cannot allocate command arguments") }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard spawned == 0 else { throw TerminalError.runtime("Cannot launch command: " + String(cString: strerror(spawned))) }
        closeOwned(output.1); closeOwned(errors.1); closeOwned(inputFD)
        var inputClosed = input == nil
        var offset = 0
        var outputData = [Data(), Data()]
        var readOpen = [true, true]
        var reaped = false
        var status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = [UInt8](repeating: 0, count: 16384)

        func reap(blocking: Bool = false) throws -> Bool {
            while true {
                let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
                if result == pid { reaped = true; return true }
                if result == 0 { return false }
                if errno == EINTR { continue }
                if errno == ECHILD { reaped = true }
                throw TerminalError.runtime("Cannot wait for command")
            }
        }
        func drain(_ index: Int, maximum: Int) throws -> Bool {
            guard readOpen[index] else { return false }
            var remaining = maximum
            var progressed = false
            while remaining > 0 {
                let count = read(readFDs[index], &bytes, min(bytes.count, remaining))
                if count < 0 && errno == EINTR { continue }
                if count == 0 { readOpen[index] = false; break }
                if count < 0 {
                    guard errno == EAGAIN || errno == EWOULDBLOCK else { throw TerminalError.runtime("Cannot read command output") }
                    break
                }
                guard count <= limit - outputData[0].count - outputData[1].count else { throw TerminalError.runtime("Command output exceeds limit") }
                outputData[index].append(contentsOf: bytes.prefix(count))
                remaining -= count; progressed = true
            }
            return progressed
        }
        do {
            while true {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw TerminalError.runtime("Command timed out") }
                var progressed = false
                for index in readFDs.indices { if try drain(index, maximum: 65536) { progressed = true } }
                if !inputClosed, let input, let incoming {
                    if offset < input.count {
                        let count = input.withUnsafeBytes { write(incoming.1, $0.baseAddress!.advanced(by: offset), min(16384, input.count - offset)) }
                        if count > 0 { offset += count; progressed = true }
                        else if count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                            inputClosed = true; closeOwned(incoming.1)
                        }
                    }
                    if offset == input.count { inputClosed = true; closeOwned(incoming.1) }
                }
                if try reap() {
                    for index in readFDs.indices where readOpen[index] {
                        var available: Int32 = 0
                        // Darwin's _IOR('f', 127, int) macro is not imported into Swift.
                        guard ioctl(readFDs[index], UInt(0x4004667f), &available) == 0 else { throw TerminalError.runtime("Cannot inspect remaining command output") }
                        if available > 0 { _ = try drain(index, maximum: Int(available)) }
                    }
                    break
                }
                if !progressed {
                    var fds = readFDs.enumerated().compactMap { readOpen[$0.offset] ? pollfd(fd: $0.element, events: Int16(POLLIN), revents: 0) : nil }
                    if !inputClosed, let incoming { fds.append(pollfd(fd: incoming.1, events: Int16(POLLOUT), revents: 0)) }
                    let wait = Int32(max(1, min(10, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
                    if poll(&fds, nfds_t(fds.count), wait) < 0 && errno != EINTR { throw TerminalError.runtime("Cannot poll command streams") }
                }
            }
            return CommandResult(status: status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f, stdout: outputData[0], stderr: outputData[1])
        } catch {
            if !reaped {
                kill(pid, SIGTERM)
                let stop = ProcessInfo.processInfo.systemUptime + 0.2
                while !reaped && ProcessInfo.processInfo.systemUptime < stop {
                    _ = try? reap()
                    if !reaped { usleep(1000) }
                }
                if !reaped { kill(pid, SIGKILL); _ = try? reap(blocking: true) }
            }
            throw error
        }
    }
}
