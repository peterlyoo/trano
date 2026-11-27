import Foundation
import Darwin

struct GitTrackingTicket: Equatable {
    let id: String
    let nonce: String
}

enum GitCommandTermination: Equatable {
    case exited(Int32)
    case signaled(Int32)
    var exitStatus: Int32 {
        switch self { case .exited(let code): return code; case .signaled(let value): return 128 + value }
    }
    var wasSignaled: Bool { if case .signaled = self { return true }; return false }
}

struct GitCommandExecution {
    let termination: GitCommandTermination
    let interrupted: Bool
}

enum TrackedGitCommand {
    static func capture(realGit: String, arguments: [String], begin: () -> GitTrackingTicket?,
                        finish: (GitTrackingTicket, Int32, Bool) -> Void,
                        run: (String, [String], String) -> GitCommandExecution?) -> GitCommandTermination? {
        guard let ticket = begin(), let result = run(realGit, arguments, ticket.id) else { return nil }
        finish(ticket, result.termination.exitStatus, result.interrupted || result.termination.wasSignaled)
        return result.termination
    }

    static func execute(realGit: String, arguments: [String], begin: () -> GitTrackingTicket?,
                        finish: (GitTrackingTicket, Int32, Bool) -> Void) -> Never {
        guard waitSemanticsSupported() else { passthrough(realGit: realGit, arguments: arguments) }
        guard let termination = capture(realGit: realGit, arguments: arguments, begin: begin, finish: finish,
                                        run: spawn) else { passthrough(realGit: realGit, arguments: arguments) }
        switch termination {
        case .exited(let code): exit(code)
        case .signaled(let value):
            signal(value, SIG_DFL)
            var mask = sigset_t(); sigemptyset(&mask); sigaddset(&mask, value)
            pthread_sigmask(SIG_UNBLOCK, &mask, nil)
            raise(value)
            _exit(128 + value)
        }
    }

    private static func passthrough(realGit: String, arguments: [String]) -> Never {
        var argv = ([realGit] + arguments).map { strdup($0) } + [nil]
        execv(realGit, &argv)
        let failure = errno
        perror("git")
        _exit(failure == ENOENT ? 127 : 126)
    }

    private static func waitSemanticsSupported() -> Bool {
        var action = sigaction()
        return sigaction(SIGCHLD, nil, &action) == 0 &&
            unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self) == 0 && action.sa_flags & SA_NOCLDWAIT == 0
    }

    private static func spawn(realGit: String, arguments: [String], captureID: String) -> GitCommandExecution? {
        guard waitSemanticsSupported(), !captureID.utf8.contains(0) else { return nil }
        var argv: [UnsafeMutablePointer<CChar>?] = [], environment: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in argv + environment { free(pointer) } }
        for value in [realGit] + arguments {
            guard let pointer = strdup(value) else { return nil }
            argv.append(pointer)
        }
        argv.append(nil)
        let key = "TRANO_WORKTREE_CAPTURE="
        var cursor = environ
        while let entry = cursor.pointee {
            if strncmp(entry, key, key.utf8.count) != 0 {
                guard let pointer = strdup(entry) else { return nil }
                environment.append(pointer)
            }
            cursor = cursor.advanced(by: 1)
        }
        guard let marker = strdup(key + captureID) else { return nil }
        environment.append(marker); environment.append(nil)
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard let relay = GitCommandSignalRelay() else { return nil }
        defer { _ = relay.stop() }
        var defaults = relay.childDefaults
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF)) == 0 else { return nil }
        var pid: pid_t = 0
        guard posix_spawn(&pid, realGit, nil, &attributes, &argv, &environment) == 0 else { return nil }
        relay.attach(pid)
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 {
            if errno == EINTR { continue }
            return relay.pollAndReap(pid)
        }
        // Keep the child waitable until the relay detaches, so its PID cannot be recycled before the last forward.
        let interrupted = relay.stop()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            return GitCommandExecution(termination: .exited(127), interrupted: true)
        }
        return GitCommandExecution(termination: decode(status), interrupted: interrupted)
    }

    fileprivate static func decode(_ status: Int32) -> GitCommandTermination {
        let value = status & 0x7f
        return value == 0 ? .exited((status >> 8) & 0xff) : .signaled(value)
    }
}

private final class GitCommandSignalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "trano.git-signals")
    private var sources: [DispatchSourceSignal] = []
    private var originals: [Int32: sigaction] = [:]
    private var pid: pid_t?
    private var pending: Set<Int32> = []
    private var interrupted = false
    private var stopped = false
    private(set) var childDefaults = sigset_t()

    init?() {
        sigemptyset(&childDefaults)
        for value in [SIGINT, SIGTERM, SIGHUP] {
            var original = sigaction()
            guard sigaction(value, nil, &original) == 0 else { _ = stop(); return nil }
            originals[value] = original
            if unsafeBitCast(original.__sigaction_u.__sa_handler, to: UInt.self) == 1 { continue }
            sigaddset(&childDefaults, value)
            var ignored = sigaction()
            ignored.__sigaction_u.__sa_handler = SIG_IGN
            sigemptyset(&ignored.sa_mask)
            guard sigaction(value, &ignored, nil) == 0 else { _ = stop(); return nil }
            let source = DispatchSource.makeSignalSource(signal: value, queue: queue)
            source.setEventHandler { [weak self] in self?.forward(value) }
            source.resume()
            sources.append(source)
        }
    }

    func attach(_ value: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pid = value
        for signal in pending { kill(value, signal) }
        pending.removeAll()
    }

    private func forward(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        interrupted = true
        if let pid { kill(pid, value) } else { pending.insert(value) }
    }

    func stop() -> Bool {
        for source in sources { source.cancel() }
        queue.sync {}
        lock.lock()
        if stopped { let result = interrupted; lock.unlock(); return result }
        stopped = true; pid = nil
        let result = interrupted
        lock.unlock()
        for (value, original) in originals {
            var action = original
            sigaction(value, &action, nil)
        }
        return result
    }

    func pollAndReap(_ child: pid_t) -> GitCommandExecution {
        while true {
            lock.lock()
            var status: Int32 = 0
            let result = waitpid(child, &status, WNOHANG)
            if result == child || result < 0 && errno != EINTR {
                pid = nil
                lock.unlock()
                let interrupted = stop()
                return result == child ? GitCommandExecution(termination: TrackedGitCommand.decode(status), interrupted: interrupted) :
                    GitCommandExecution(termination: .exited(127), interrupted: true)
            }
            lock.unlock()
            usleep(10_000)
        }
    }
}
