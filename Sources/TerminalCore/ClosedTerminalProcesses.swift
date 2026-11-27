import Foundation
import Darwin

enum ClosedTerminalProcesses {
    struct Process: Equatable {
        let identity: SupervisorProcessIdentity
        let parentPID: Int32
    }

    struct Environment {
        let ownerUID: UInt32
        let selfPID: Int32
        let pids: () throws -> [Int32]
        let process: (Int32) throws -> Process?
        let hasExited: (SupervisorProcessIdentity) -> Bool
        let signal: (Int32, Int32) -> Int32
        let now: () -> TimeInterval
        let wait: (TimeInterval) -> Void

        static var native: Environment {
            .init(ownerUID: getuid(), selfPID: getpid(), pids: ClosedTerminalProcesses.ownedPIDs,
                process: ClosedTerminalProcesses.readProcess,
                hasExited: ClosedAgentRecovery.processHasExited, signal: { Darwin.kill($0, $1) },
                now: { ProcessInfo.processInfo.systemUptime }, wait: { Thread.sleep(forTimeInterval: $0) })
        }
    }

    private static let maximumProcesses = 65_536

    static func capture(pane: TerminalSession, launch: AgentLaunch?) -> [SupervisorProcessIdentity] {
        capture(pane: pane, launch: launch, environment: .native)
    }

    static func capture(pane: TerminalSession, launch: AgentLaunch?, environment: Environment) -> [SupervisorProcessIdentity] {
        (try? captureVerified(pane: pane, launch: launch, environment: environment)) ?? []
    }

    static func captureVerified(pane: TerminalSession, launch: AgentLaunch?) throws -> [SupervisorProcessIdentity] {
        try captureVerified(pane: pane, launch: launch, environment: .native)
    }

    static let inspectFailure = "Cannot inspect a terminal process safely"

    // The census covers every process the user owns, so one that changes state mid-scan fails the probe. A fresh
    // census clears that race; a probe that keeps failing still aborts the close.
    static func captureVerified(pane: TerminalSession, launch: AgentLaunch?, environment: Environment) throws -> [SupervisorProcessIdentity] {
        for _ in 0..<2 {
            do { return try captureCensus(pane: pane, launch: launch, environment: environment) }
            catch TerminalError.runtime(let reason) where reason == inspectFailure { environment.wait(0.01) }
        }
        return try captureCensus(pane: pane, launch: launch, environment: environment)
    }

    private static func captureCensus(pane: TerminalSession, launch: AgentLaunch?, environment: Environment) throws -> [SupervisorProcessIdentity] {
        guard pane.alive, pane.pid > 1, let root = try environment.process(pane.pid) else { return [] }
        guard root.identity.ownerUID == environment.ownerUID else { throw TerminalError.invalid("Terminal process owner changed") }
        let census = try environment.pids()
        guard census.count < maximumProcesses else { throw TerminalError.runtime("Terminal process census is incomplete") }
        let explicit = [pane.pid, launch?.processID, launch?.providerPID].compactMap { $0 }
        var records: [Int32: Process] = [:]
        for pid in explicit + census where records[pid] == nil {
            guard pid > 1, let process = try environment.process(pid),
                  process.identity.ownerUID == environment.ownerUID else { continue }
            records[pid] = process
            guard records.count < maximumProcesses else { throw TerminalError.runtime("Terminal process census is incomplete") }
        }
        guard records[pane.pid] == root, try environment.process(pane.pid) == root else {
            throw TerminalError.invalid("Terminal process changed during capture")
        }
        var children: [Int32: [Int32]] = [:]
        for (pid, process) in records { children[process.parentPID, default: []].append(pid) }
        var queue: [(pid: Int32, depth: Int, excluded: Bool)] = [(pane.pid, 0, false)]
        var visited: Set<Int32> = []
        var captured: [(identity: SupervisorProcessIdentity, depth: Int)] = []
        var index = 0
        while index < queue.count {
            guard index < maximumProcesses else { throw TerminalError.runtime("Terminal process traversal is incomplete") }
            let entry = queue[index]; index += 1
            guard visited.insert(entry.pid).inserted, let process = records[entry.pid],
                  try environment.process(entry.pid) == process else { continue }
            let excluded = entry.excluded || entry.pid == environment.selfPID
            if !excluded { captured.append((process.identity, entry.depth)) }
            for child in (children[entry.pid] ?? []).sorted() where !visited.contains(child) {
                queue.append((child, entry.depth + 1, excluded))
                guard queue.count < maximumProcesses else { throw TerminalError.runtime("Terminal process traversal is incomplete") }
            }
        }
        guard try environment.process(pane.pid) == root else { throw TerminalError.invalid("Terminal process changed during capture") }
        return captured.sorted {
            $0.depth == $1.depth ? $0.identity.pid < $1.identity.pid : $0.depth > $1.depth
        }.map(\.identity)
    }

    static func stop(_ witnesses: [SupervisorProcessIdentity]) throws {
        try stop(witnesses, environment: .native)
    }

    static func stop(_ witnesses: [SupervisorProcessIdentity], environment: Environment) throws {
        var identities: [Int32: SupervisorProcessIdentity] = [:]
        var targets: [SupervisorProcessIdentity] = []
        for witness in witnesses where witness.pid != environment.selfPID {
            guard witness.pid > 1, witness.ownerUID == environment.ownerUID,
                  witness.startedAtSeconds > 0, witness.startedAtMicroseconds < 1_000_000 else {
                throw TerminalError.invalid("Cannot verify a saved terminal process identity")
            }
            if let previous = identities[witness.pid] {
                guard previous == witness else { throw TerminalError.invalid("Conflicting saved terminal process identities") }
            } else { identities[witness.pid] = witness; targets.append(witness) }
        }
        let started = environment.now(), deadline = started + 1
        func pending(_ values: [SupervisorProcessIdentity]) throws -> [SupervisorProcessIdentity] {
            try values.filter { witness in
                if environment.hasExited(witness) { return false }
                guard try environment.process(witness.pid)?.identity == witness else {
                    throw TerminalError.invalid("Cannot verify whether a terminal process has exited")
                }
                return true
            }
        }
        func send(_ values: [SupervisorProcessIdentity], signal: Int32) throws {
            for witness in values {
                if environment.hasExited(witness) { continue }
                guard environment.now() < deadline,
                      try environment.process(witness.pid)?.identity == witness else {
                    throw TerminalError.invalid("Terminal process identity changed before stopping it")
                }
                if environment.signal(witness.pid, signal) != 0, !environment.hasExited(witness) {
                    throw TerminalError.runtime("A terminal process could not be stopped safely")
                }
            }
        }
        func waitForExit(_ values: [SupervisorProcessIdentity], until limit: TimeInterval) throws -> [SupervisorProcessIdentity] {
            var remaining = try pending(values)
            for _ in 0..<128 {
                guard !remaining.isEmpty, environment.now() < limit else { break }
                environment.wait(min(0.01, max(0, limit - environment.now())))
                remaining = try pending(remaining)
            }
            return remaining
        }
        targets = try pending(targets)
        try send(targets, signal: SIGTERM)
        targets = try waitForExit(targets, until: min(started + 0.2, deadline))
        guard !targets.isEmpty else { return }
        try send(targets, signal: SIGKILL)
        guard try waitForExit(targets, until: deadline).isEmpty else {
            throw TerminalError.runtime("Terminal processes are still exiting. Saved state was retained; retry after they stop.")
        }
    }

    private static func ownedPIDs() throws -> [Int32] {
        var pids = [Int32](repeating: 0, count: maximumProcesses)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, capacity) }
        guard count > 0, count < capacity, count % Int32(MemoryLayout<Int32>.stride) == 0 else {
            throw TerminalError.runtime("Cannot obtain a complete terminal process census")
        }
        return Array(pids.prefix(Int(count) / MemoryLayout<Int32>.stride)).filter { $0 > 1 }
    }

    private static func readProcess(_ pid: Int32) throws -> Process? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if count <= 0, errno == ESRCH { return nil }
        guard count == size, info.pbi_pid == UInt32(pid) else {
            throw TerminalError.runtime(inspectFailure)
        }
        if info.pbi_status == 5 { return nil }
        return Process(identity: .init(pid: pid, ownerUID: info.pbi_uid,
            startedAtSeconds: info.pbi_start_tvsec, startedAtMicroseconds: info.pbi_start_tvusec),
            parentPID: Int32(bitPattern: info.pbi_ppid))
    }
}
