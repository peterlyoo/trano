import Foundation

public final class PessimisticTwinWorker {
    private let runtime: TerminalRuntime
    private let queue = DispatchQueue(label: "trano.pessimistic-twins", qos: .utility)
    private let lock = NSLock()
    private var active = true
    private var timer: DispatchSourceTimer?
    private var sockets: [String: APIService] = [:]
    public init(runtime: TerminalRuntime) { self.runtime = runtime }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil, active else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(750), leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }

    public func stop() {
        lock.lock(); active = false; let timer = self.timer; self.timer = nil; lock.unlock()
        timer?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for service in self.sockets.values { service.stop() }
            self.sockets.removeAll()
        }
    }

    private func tick() {
        guard isActive else { return }
        do {
            try TwinWorkerIteration(active: { self.isActive }, load: { try self.runtime.pessimisticTwins() },
                scopes: { Set(self.sockets.keys) }, startScope: { run in
                    let service = APIService(runtime: self.runtime, twinScope: TwinAPIScope(runID: run.id))
                    try service.start(); self.sockets[run.id] = service
                }, stopScope: { self.sockets.removeValue(forKey: $0)?.stop() },
                inspectReview: { try self.inspectReview($0) }, hold: { try self.holdFailedRun($0, message: $1) },
                diagnostic: { self.recordDiagnostic($0) }, advance: {
                    _ = try self.runtime.twinCoordinator(active: { [weak self] in self?.isActive == true }).processPending()
                }).run()
        } catch { recordDiagnostic(error.localizedDescription) }
    }

    private func holdFailedRun(_ expected: TwinRun, message: String) throws -> Bool {
        try runtime.transaction {
            guard isActive else { return false }
            return try TwinStore(root: runtime.root).transaction { value in
                guard let index = value.runs.firstIndex(where: { $0.id == expected.id }),
                      let held = TwinWorkerIteration.heldRun(current: value.runs[index], expected: expected, message: message, now: Date()) else { return false }
                value.runs[index] = held
                return true
            }
        }
    }
    private var lastDiagnostic: String?
    private func recordDiagnostic(_ detail: String) {
        let message = TwinWorkerIteration.boundedMessage(detail)
        guard lastDiagnostic != message else { return }
        do {
            try TerminalRuntime.atomicWrite(Data((message + "\n").utf8), to: runtime.root.appendingPathComponent("pessimistic-twin-diagnostic"))
            lastDiagnostic = message
        } catch {}
    }

    private func inspectReview(_ run: TwinRun) throws {
        guard isActive, let round = run.latestRound else { return }
        let ticket = try runtime.twinLaunchTicket(runID: run.id, round: round.number)
        if try runtime.acknowledgeTwinRestrictedStartup(run: run, round: round, active: { self.isActive }) { return }
        if round.report == nil, let report = ticket.reportedEnvelope, let at = ticket.reportedAt {
            try runtime.transaction {
                guard let current = try runtime.requireTwin(run.id).latestRound, current.number == round.number,
                      let pane = current.pane else { return }
                try runtime.twinCoordinator().submitReport(runID: run.id, round: round.number, pane: pane,
                    report: report, reportedAt: at, reportedTurnID: ticket.reportedTurnID)
            }
        }
        if let code = ticket.providerExitCode, code != 0 || ticket.reportedEnvelope == nil || ticket.lastCompletion == nil {
            try runtime.transaction {
                try TwinStore(root: runtime.root).transaction { value in
                    guard let index = value.runs.firstIndex(where: { $0.id == run.id && $0.phase == .reviewing && $0.operation == nil }) else { return }
                    value.runs[index].phase = .cleaning
                    value.runs[index].exitReason = code == 0 ? .invalidAgentOutput : .agentUnavailable
                    value.runs[index].message = code == 0 ? "The twin exited without a valid report and trusted completed turn." : "The twin provider exited with code \(code)."
                    value.runs[index].updatedAt = Date()
                }
            }
            return
        }
        let state = try runtime.state()
        if let launch = state.agentLaunches.first(where: { $0.id == ticket.generation }),
           launch.providerSessionID == nil && Date().timeIntervalSince(launch.updatedAt) > 30 {
            try runtime.transaction {
                try TwinStore(root: runtime.root).transaction { value in
                    guard let index = value.runs.firstIndex(where: { $0.id == run.id && $0.phase == .reviewing }) else { return }
                    value.runs[index].phase = .needsReview
                    value.runs[index].exitReason = .agentUnavailable
                    value.runs[index].message = "Provider did not confirm a fresh fork within 30 seconds. Inspect the twin pane for authentication, hook trust, or sandbox startup errors."
                    value.runs[index].updatedAt = Date()
                }
            }
        }
    }
}
