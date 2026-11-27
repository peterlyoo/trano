import Foundation
import Darwin
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
    private var observedBoundary: BoundaryObservation?

    private struct BoundaryObservation {
        let files: [BoundaryFile]
        let monitor: AgentSupervision?
    }

    private enum BoundaryFile: Equatable {
        case absent
        case present(FileIdentity)
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: time_t
        let modifiedNanoseconds: Int
        let changedSeconds: time_t
        let changedNanoseconds: Int
        let mode: mode_t
        let owner: uid_t
        let links: nlink_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
            mode = info.st_mode
            owner = info.st_uid
            links = info.st_nlink
        }
    }

    init(runtime: TerminalRuntime, launch: AgentLaunch) { self.runtime = runtime; self.launch = launch }

    func observeBoundary(with relay: ProviderSignalRelay) throws {
        let files = boundaryFileIdentities()
        let monitor: AgentSupervision?
        if let files, let observedBoundary, files == observedBoundary.files {
            monitor = observedBoundary.monitor
        } else {
            observedBoundary = nil
            monitor = try runtime.state().supervision.first(where: { $0.generation == launch.id })
            if let files, files == boundaryFileIdentities() {
                observedBoundary = BoundaryObservation(files: files, monitor: monitor)
            }
        }
        if let monitor {
            relay.observeBoundary(revision: monitor.boundaryRevision, safe: monitor.safeToSwitch)
        }
    }

    private func boundaryFileIdentities() -> [BoundaryFile]? {
        var files: [BoundaryFile] = []
        for name in ["state.json", "continuity.json", "account-organizations-v1.json"] {
            var info = stat()
            guard lstat(runtime.root.appendingPathComponent(name).path, &info) == 0 else {
                if errno == ENOENT { files.append(.absent); continue }
                return nil
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0 else { return nil }
            files.append(.present(FileIdentity(info)))
        }
        return files
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
                  let current = state.accounts.first(where: { $0.id == currentID }), !current.pinned,
                  current.organizationUsageBindingID == launch.organizationBindingID else { return nil }
            func signature(_ value: AccountUsageSnapshot?) -> String {
                "\(monitor.boundaryRevision):\(value?.organizationBindingID ?? "legacy"):\(value?.status.rawValue ?? "unknown"):\(value?.observedAt.timeIntervalSince1970 ?? 0)"
            }
            let cached = try runtime.accountUsage().first { $0.accountID == currentID }
            guard signature(cached) != checkedUsage else { return nil }
            checkedUsage = signature(cached)
            let usage = try runtime.refreshAccountUsage(accountID: currentID)
            checkedUsage = signature(usage)
            guard usage.status == .limited, usage.organizationBindingID == launch.organizationBindingID else { return nil }
            let snapshots = try runtime.accountUsage()
            for candidate in state.accounts where candidate.provider == launch.provider && candidate.id != currentID && candidate.enabled && !candidate.pinned && (candidate.unavailableUntil ?? .distantPast) <= Date() {
                do { _ = try runtime.preflightAccountOrganization(accountID: candidate.id, cwd: launch.cwd) }
                catch { continue }
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
        guard plan.providerPID == childPID else { throw TerminalError.runtime("Agent changed before account switching") }
        if let authorization = plan.organizationAuthorization { try runtime.revalidateAccountOrganizationAuthorization(authorization, cwd: plan.cwd) }
        guard kill(childPID, SIGSTOP) == 0 else { throw TerminalError.runtime("Agent exited before account switching") }
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
