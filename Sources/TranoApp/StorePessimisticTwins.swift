import AppKit
import TerminalCore

extension AppStore {
    func reloadPessimisticTwins() {
        guard externalPanePolicy == nil else { return }
        let runtime = runtime
        queue.async { [weak self] in
            do {
                let runs = try runtime.pessimisticTwins()
                DispatchQueue.main.async { if self?.pessimisticTwinRuns != runs { self?.pessimisticTwinRuns = runs } }
            } catch { DispatchQueue.main.async { self?.twinActionError = error.localizedDescription } }
        }
    }
    func currentTwin(paneID: String) -> TwinRun? {
        pessimisticTwinRuns.first { $0.isActive && ($0.source.paneID == paneID || $0.rounds.contains { $0.pane?.paneID == paneID }) }
    }
    func enableTwin(paneID: String, mode: TwinReviewMode) {
        guard !twinBusy.contains(paneID), externalPanePolicy == nil else { return }
        let launches = state.agentLaunches.filter { $0.paneID == paneID && $0.lifecycle == .active }
        guard launches.count == 1, let launch = launches.first, let conversationID = launch.providerSessionID,
              let pane = sessions.first(where: { $0.id == paneID && $0.alive && $0.remote == nil }),
              PessimisticTwinMenuTarget.startable(local: true, alive: pane.alive, backendPID: pane.pid,
                launcherPID: launch.processID, providerPID: launch.providerPID, provider: launch.provider, conversationID: conversationID) else {
            twinActionError = "Open a local managed Claude or Codex conversation first."; showActivity = true; return
        }
        let expectedSource = TwinSourceExpectation(generation: launch.id, conversationID: conversationID, cwd: launch.cwd)
        mutateTwin(key: paneID) { _ = try $0.enablePessimisticTwin(paneID: paneID, mode: mode, expectedSource: expectedSource) }
    }
    func stopTwin(id: String) {
        guard !twinBusy.contains(id) else { return }
        mutateTwin(key: id) { try $0.stopPessimisticTwin(id: id) }
    }
    private func mutateTwin(key: String, work: @escaping (TerminalRuntime) throws -> Void) {
        twinBusy.insert(key); twinActionError = nil
        let runtime = runtime
        queue.async { [weak self] in
            let failure: String?
            do { try work(runtime); failure = nil } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self?.twinBusy.remove(key); self?.twinActionError = failure
                if failure != nil { self?.showActivity = true }
                self?.reloadPessimisticTwins()
            }
        }
    }
    func toggleTwinModePicker(paneID: String) {
        guard externalPanePolicy == nil, safeInterfaceNavigation,
              let owner = NSApp.keyWindow, let content = owner.contentView,
              (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        commandKeyHints.cancel()
        let captured = PessimisticTwinMenuTarget.capture(store: self, paneID: paneID)
        guard captured.canStart || captured.activeRunID != nil else { twinActionError = "Open a local managed Claude or Codex conversation first."; showActivity = true; return }
        let anchor = PessimisticTwinNativeButton(frame: NSRect(x: max(0, content.bounds.width - 42), y: max(0, content.bounds.height - 58), width: 22, height: 22))
        anchor.menuTarget = captured
        anchor.run = currentTwin(paneID: paneID)
        anchor.currentTarget = { [weak self] in self.map { PessimisticTwinMenuTarget.capture(store: $0, paneID: paneID) } }
        anchor.enable = { [weak self] mode in self?.enableTwin(paneID: paneID, mode: mode) }
        anchor.stop = { [weak self] id in self?.stopTwin(id: id) }
        content.addSubview(anchor)
        defer { anchor.removeFromSuperview() }
        anchor.invoke(nil)
    }
}
