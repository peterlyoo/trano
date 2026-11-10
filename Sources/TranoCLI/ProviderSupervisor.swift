import Foundation
import TerminalCore

func boundedHookInput() throws -> Data {
    var data = Data()
    guard isatty(STDIN_FILENO) == 0 else { return data }
    while let part = try FileHandle.standardInput.read(upToCount: min(8192, 1_048_577 - data.count)), !part.isEmpty {
        data.append(part)
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Hook input exceeds 1 MiB") }
    }
    return data
}

final class ProviderSupervisor {
    let runtime: TerminalRuntime
    let launch: AgentLaunch
    private var observedModification: [Date?] = []
    private var checkedUsage = ""

    init(runtime: TerminalRuntime, launch: AgentLaunch) { self.runtime = runtime; self.launch = launch }

    func observeBoundary(with relay: ProviderSignalRelay) throws {
        if let monitor = try runtime.state().supervision.first(where: { $0.generation == launch.id }) {
            relay.observeBoundary(revision: monitor.boundaryRevision, safe: monitor.safeToSwitch)
        }
    }

    func pendingSwitch() throws -> AccountSwitchPlan? {
        guard let currentID = launch.accountID else { return nil }
        let modified = ["state.json", "account-usage.json"].map { file in
            (try? FileManager.default.attributesOfItem(atPath: runtime.root.appendingPathComponent(file).path)[.modificationDate]) as? Date
        }
        guard modified != observedModification else { return nil }
        observedModification = modified
        let state = try runtime.state()
        guard let monitor = state.supervision.first(where: { $0.generation == launch.id }), monitor.safeToSwitch else { return nil }
        var target = monitor.targetAccountID
        if target == nil {
            guard state.settings.automaticAccountSwitching,
                  let current = state.accounts.first(where: { $0.id == currentID }), !current.pinned else { return nil }
            func signature(_ value: AccountUsageSnapshot?) -> String {
                "\(monitor.boundaryRevision):\(value?.status.rawValue ?? "unknown"):\(value?.observedAt.timeIntervalSince1970 ?? 0)"
            }
            let cached = try runtime.accountUsage().first { $0.accountID == currentID }
            guard signature(cached) != checkedUsage else { return nil }
            checkedUsage = signature(cached)
            let usage = try runtime.refreshAccountUsage(accountID: currentID)
            checkedUsage = signature(usage)
            guard usage.status == .limited else { return nil }
            let snapshots = try runtime.accountUsage()
            for candidate in state.accounts where candidate.provider == launch.provider && candidate.id != currentID && candidate.enabled && !candidate.pinned && (candidate.unavailableUntil ?? .distantPast) <= Date() {
                var status = snapshots.first { $0.accountID == candidate.id }?.status ?? .unknown
                if candidate.provider == .codex, status != .available { status = try runtime.refreshAccountUsage(accountID: candidate.id).status }
                if status == .available { target = candidate.id; break }
                if status == .unknown, try runtime.accountAuthentication(accountID: candidate.id).status == .authenticated {
                    target = candidate.id; break
                }
            }
            guard target != nil else {
                try runtime.recordSwitchMessage(generation: launch.id, message: "Quota reached; no eligible account is available")
                try runtime.report(launch.paneID, state: .blocked, reason: "Quota reached; no eligible account is available", agent: launch.provider, source: "process")
                return nil
            }
        }
        guard let target else { return nil }
        do {
            return try runtime.prepareAccountSwitch(paneID: launch.paneID, targetAccountID: target, expectedGeneration: launch.id,
                                                    toolsInFlight: !monitor.activeTools.isEmpty || monitor.unknownToolCount > 0, safeTurnBoundary: monitor.safeToSwitch)
        } catch {
            try runtime.recordSwitchMessage(generation: launch.id, message: error.localizedDescription, clearRequest: true)
            return nil
        }
    }

    func stopForSwitch(_ plan: AccountSwitchPlan, childPID: pid_t) throws {
        guard plan.providerPID == childPID, kill(childPID, SIGSTOP) == 0 else { throw TerminalError.runtime("Agent exited before account switching") }
        do {
            try runtime.transaction {
                try runtime.validateAccountSwitch(plan)
                guard try runtime.state().supervision.first(where: { $0.generation == launch.id })?.safeToSwitch == true else {
                    throw TerminalError.invalid("Agent started another turn; switch postponed")
                }
                guard kill(childPID, SIGTERM) == 0 else { throw TerminalError.runtime("Cannot stop the current agent") }
            }
        } catch { kill(childPID, SIGCONT); throw error }
        kill(childPID, SIGCONT)
    }
}
