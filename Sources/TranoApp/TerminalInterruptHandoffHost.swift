import AppKit
import TerminalCore

extension TranoView {
    func handleInterruptHandoff(_ event: NSEvent) -> Bool { interruptHandoff.handle(event) }

    func captureInterruptHandoff() -> TerminalInterruptHandoff.Target? {
        guard let store, let window, store.focusedID == paneID, store.terminalViews[paneID] === self,
              let pane = store.sessions.first(where: { $0.id == paneID && $0.alive }),
              let owner = interactionOwner(), let lease = interactionLease(for: owner),
              interruptHandoffApplicationActive(), TerminalHistoryReplayFocus.ownsInput(self, in: window),
              store.safeInterfaceNavigation, !inputBlocked else { return nil }
        let launches = store.state.agentLaunches.filter { $0.paneID == paneID }
        let active = launches.filter { $0.lifecycle == .active }
        guard active.count <= 1 else { return nil }
        let provider = active.first?.provider ?? pane.agent
        guard provider == .claude || provider == .codex || pane.displayProgram == .claude || pane.displayProgram == .codex else { return nil }
        let clientPID = process.shellPid, backendPID = pane.pid, remote = pane.remote
        let backend = SupervisorProcessIdentity.read(backendPID)
        let processes = [active.first?.processID, active.first?.providerPID].compactMap { $0 }.compactMap(SupervisorProcessIdentity.read)
        var request = TerminalShellHandoffRequest(paneID: paneID, backendPID: backendPID, remote: remote, backend: backend,
            launchIDs: Set(launches.map(\.id)), activeLaunchID: active.first?.id, processes: processes)
        request.remoteBackendIdentity = pane.inputBackendIdentity
        request.providerPID = active.first?.providerPID; request.supervisorPID = active.first?.processID
        let frozenRequest = request, knownIDs = request.launchIDs, remoteIdentity = request.remoteBackendIdentity
        let launchID = active.first?.id
        let providerPID = active.first?.providerPID
        let owns: () -> Bool = { [weak self, weak store, weak window] in
            guard let self, let store, let window, lease.isValid, self.store === store, self.window === window,
                  store.terminalViews[owner.paneID] === self, store.focusedID == owner.paneID,
                  self.process.shellPid == clientPID, self.interruptHandoffApplicationActive(),
                  self.retainsInterruptInput(owner: owner, lease: lease), store.sessions.contains(where: { $0.id == owner.paneID && $0.pid == backendPID && $0.remote == remote && $0.alive && (remote == nil || $0.inputBackendIdentity == remoteIdentity) }),
                  store.headerMenuAllowsActions, !self.inputBlocked, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  self.interruptHandoff.isReplaying || !self.hasMarkedText(),
                  TerminalHistoryReplayFocus.ownsInput(self, in: window) else { return false }
            guard store.state.agentLaunches.filter({ $0.paneID == owner.paneID }).allSatisfy({ knownIDs.contains($0.id) }) else { return false }
            return store.state.agentLaunches.filter { $0.paneID == owner.paneID && $0.lifecycle == .active }.allSatisfy { $0.id == launchID && $0.providerPID == providerPID }
        }
        var ready: TerminalShellHandoffSnapshot?
        var observedInput = terminalInputStateSnapshot()
        var modeRevision = UUID()
        let runtime = store.runtime, queue = store.queue
        let probe: (@escaping (TerminalInterruptHandoff.Readiness) -> Void) -> Void = { [weak self, weak store] completion in
            let finish: (TerminalShellHandoffStatus) -> Void = { [weak self, weak store] status in
                guard let self, store != nil, owns() else { completion(.changed); return }
                switch status {
                case .waiting: completion(.waiting)
                case .changed: completion(.changed)
                case .unavailable(let message): self.interruptHandoff.cancel(); store?.message = message; completion(.changed)
                case .ready(let value):
                    guard let input = self.terminalInputStateSnapshot() else { completion(.waiting); return }
                    if observedInput != input { observedInput = input; modeRevision = UUID() }
                    ready = value; completion(.ready(value.identity + ":" + modeRevision.uuidString))
                }
            }
            if let probe = self?.interruptHandoffProbe { probe(frozenRequest, finish); return }
            queue.async {
                let status = (try? runtime.terminalShellHandoff(frozenRequest)) ?? .waiting
                DispatchQueue.main.async { finish(status) }
            }
        }
        return TerminalInterruptHandoff.Target(ownsInput: owns, probe: probe, prepare: { [weak self, weak store] in
            guard let self, let store, owns(), let ready else { return }
            var state = store.state
            state.agentLaunches = state.agentLaunches.filter { $0.paneID != owner.paneID } + ready.launches
            store.state = state
            self.installTerminalInputRelay(store: store, id: owner.paneID, expectedPID: backendPID, authoritativeBinding: ready.binding)
            self.interruptInputAdmission.begin(knownIDs)
        }, didReplay: { [weak self] in self?.interruptInputAdmission.end() }, pollInterval: remote == nil ? 0.04 : 0.4)
    }
}
