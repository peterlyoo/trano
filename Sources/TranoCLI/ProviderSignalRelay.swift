import Foundation
import Darwin
import TerminalCore

final class ProviderSignalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var lastSignal: Int32?
    private var boundaryRevision = 0
    private var interruptedBoundary = 0
    private var stoppedSignal: Int32?

    func setPID(_ value: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pid = value
        stoppedSignal = nil
        boundaryRevision = 0
        interruptedBoundary = 0
        if let lastSignal { kill(-value, lastSignal) }
    }

    var lastSignalValue: Int32? { lock.lock(); defer { lock.unlock() }; return lastSignal }
    var wasInterrupted: Bool { lock.lock(); defer { lock.unlock() }; return lastSignal != nil }
    var stoppedSignalValue: Int32? { lock.lock(); defer { lock.unlock() }; return stoppedSignal }

    func observeBoundary(revision: Int, safe: Bool) {
        lock.lock(); defer { lock.unlock() }
        if pid != nil, lastSignal == SIGINT, safe, revision > interruptedBoundary { lastSignal = nil }
        boundaryRevision = revision
    }

    func send(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        if lastSignal == SIGTERM { return }
        lastSignal = value
        interruptedBoundary = boundaryRevision
        if let pid { kill(-pid, value) }
    }

    func stop() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        pid = nil
        stoppedSignal = lastSignal
        lastSignal = nil
        return stoppedSignal
    }
}

struct ProviderTerminalControl {
    private let descriptor: Int32
    private let originalGroup: pid_t?

    init(descriptor: Int32 = STDIN_FILENO) {
        self.descriptor = descriptor
        let foreground = tcgetpgrp(descriptor)
        originalGroup = foreground > 0 && foreground == getpgrp() ? foreground : nil
    }

    func give(to group: pid_t) throws {
        guard originalGroup != nil else { return }
        guard foreground(group) == 0 else { throw TerminalError.runtime("Cannot give the provider terminal control") }
    }

    func restore() {
        if let originalGroup { _ = foreground(originalGroup) }
    }

    private func foreground(_ group: pid_t) -> Int32 {
        var blocked = sigset_t(), previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTTOU)
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        return tcsetpgrp(descriptor, group)
    }
}
