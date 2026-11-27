import Foundation
import Darwin

struct TwinProviderRetirement {
    let signal: Int32?
    let marker: String?

    static func canInterruptReview(reason: TwinExitReason?, expectedFingerprint: String?, fingerprint: String, pendingDecision: Bool) -> Bool {
        guard let reason, [.userInterrupt, .agentUnavailable, .invalidAgentOutput].contains(reason),
              let expectedFingerprint, expectedFingerprint == fingerprint, !pendingDecision else { return false }
        return true
    }

    static func request(stages: [String], now: Date) throws -> Self {
        let prefix = "providerStopRequested:"
        let requested = stages.filter { $0.hasPrefix(prefix) }
        guard requested.count <= 1, stages.filter({ $0 == "providerKillRequested" }).count <= 1,
              now.timeIntervalSince1970.isFinite else { throw TerminalError.invalid("Twin process retirement journal is invalid") }
        guard let first = requested.first else {
            guard !stages.contains("providerKillRequested") else { throw TerminalError.invalid("Twin retirement lacks its stop receipt") }
            return Self(signal: SIGTERM, marker: prefix + String(now.timeIntervalSince1970))
        }
        guard let started = TimeInterval(first.dropFirst(prefix.count)), started.isFinite else {
            throw TerminalError.invalid("Twin retirement time is invalid")
        }
        if stages.contains("providerKillRequested") || now.timeIntervalSince1970 < started + 5 {
            return Self(signal: nil, marker: nil)
        }
        return Self(signal: SIGKILL, marker: "providerKillRequested")
    }
}

enum TwinUnclaimedRoundResources {
    static func requireAbsent(path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw TerminalError.invalid("A partial twin round needs inspection before cleanup") }
        guard let directory = fdopendir(descriptor) else { close(descriptor); throw TerminalError.invalid("Cannot inspect partial twin resources") }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { throw TerminalError.invalid("A partial twin snapshot or profile needs inspection before cleanup") }
            errno = 0
        }
        guard errno == 0 else { throw TerminalError.invalid("Partial twin resource inspection was incomplete") }
    }
}
