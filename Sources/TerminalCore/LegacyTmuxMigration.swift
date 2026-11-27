import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct LegacyTmuxMigrationResult: Codable {
    public var migrated: [String] = []
    public var failed: [String: String] = [:]
    public var recovery: [RecoveryResult] = []
}

extension TerminalRuntime {
    struct LegacyTmuxPane: Equatable {
        let id: String
        let pid: Int32
        let alive: Bool
    }

    static func parseLegacyTmuxPanes(_ output: String) -> [LegacyTmuxPane] {
        var seen: Set<String> = []
        return output.split(separator: "\n").prefix(4096).compactMap { row in
            let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, UUID(uuidString: fields[0]) != nil, let pid = Int32(fields[1]), pid > 1,
                  fields[2] == "0" || fields[2] == "1", seen.insert(fields[0]).inserted else { return nil }
            return LegacyTmuxPane(id: fields[0], pid: pid, alive: fields[2] == "0")
        }
    }

    func legacyTmuxPanes() throws -> [LegacyTmuxPane] {
        guard legacyTmuxExecutable != nil, FileManager.default.fileExists(atPath: legacySocketPath) else { return [] }
        return Self.parseLegacyTmuxPanes(try legacyTmux(["list-panes", "-a", "-F", "#{session_name}|#{pane_pid}|#{pane_dead}"], allowFailure: true))
    }

    /// Moves panes still hosted by a legacy tmux server onto the PTY host. A live pane cannot hand its PTY
    /// master to another process, so each one is stopped and then restored through ordinary recovery, which
    /// resumes active Claude/Codex conversations by provider session ID and restores other panes as shells.
    @discardableResult
    public func migrateLegacyTmuxPanes(exitTimeout: TimeInterval = 10) throws -> LegacyTmuxMigrationResult {
        try assertOutsideSharedTransaction()
        var result = LegacyTmuxMigrationResult()
        let legacy = try legacyTmuxPanes()
        guard !legacy.isEmpty else {
            try removeIdleLegacyServer()
            return result
        }
        let known = Set(try state().sessions.map(\.id))
        let targets = legacy.filter { known.contains($0.id) }
        let launchPIDs = try state().agentLaunches.filter { $0.lifecycle == .active }
            .reduce(into: [String: Int32]()) { values, launch in if let pid = launch.processID { values[launch.paneID] = pid } }
        for pane in targets {
            try transaction {
                if let hosted = try host.pane(pane.id), hosted.alive {
                    result.failed[pane.id] = "The PTY host already runs this pane; the legacy copy was left untouched"
                    return
                }
                _ = try legacyTmux(["kill-session", "-t", "=" + pane.id], allowFailure: true)
            }
        }
        let deadline = Date().addingTimeInterval(exitTimeout)
        for pane in targets where result.failed[pane.id] == nil {
            let stillListed = { try self.legacyTmuxPanes().contains { $0.id == pane.id } }
            let processes = [pane.pid] + (launchPIDs[pane.id].map { [$0] } ?? [])
            while Date() < deadline, try stillListed() || processes.contains(where: Self.processExists) { usleep(50_000) }
            if try stillListed() {
                result.failed[pane.id] = "The legacy terminal did not stop"
            } else if let survivor = processes.first(where: Self.processExists) {
                result.failed[pane.id] = "Process \(survivor) from the legacy terminal is still running"
            } else {
                result.migrated.append(pane.id)
            }
        }
        for id in result.migrated {
            do { result.recovery += try recoverSessions(paneID: id) }
            catch { result.failed[id] = error.localizedDescription }
        }
        try removeIdleLegacyServer()
        return result
    }

    private func removeIdleLegacyServer() throws {
        guard legacyTmuxExecutable != nil, FileManager.default.fileExists(atPath: legacySocketPath) else { return }
        let sessions = try legacyTmux(["list-sessions", "-F", "#{session_name}"], allowFailure: true)
        guard sessions.split(separator: "\n").isEmpty else { return }
        _ = try legacyTmux(["kill-server"], allowFailure: true)
        try? FileManager.default.removeItem(atPath: legacySocketPath)
    }

    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
