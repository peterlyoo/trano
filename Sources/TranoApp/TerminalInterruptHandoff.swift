import AppKit

@MainActor final class TerminalInterruptHandoff {
    enum Readiness { case waiting, ready(String), changed }
    struct Target {
        let ownsInput: () -> Bool
        let probe: (@escaping (Readiness) -> Void) -> Void
        let prepare: () -> Void
        var didReplay: () -> Void = {}
        var pollInterval: TimeInterval = 0.04
    }
    var capture: () -> Target? = { nil }
    var replay: (NSEvent) -> Void = { _ in }
    var report: (String) -> Void = { _ in }
    private var firstInterrupt: TimeInterval?
    private var candidate: Target?
    private var target: Target?
    private var events: [NSEvent] = []
    private var cost = 0
    private var generation = UUID()
    private var work: DispatchWorkItem?
    private var inFlight = false
    private var lastReady: String?
    private var queuedKeys: Set<UInt16> = []
    var isWaiting: Bool { target != nil }
    private(set) var isReplaying = false

    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let interrupt = flags == .control && (event.charactersIgnoringModifiers?.lowercased() == "c" || event.characters == "\u{3}")
        if interrupt {
            if event.type == .keyUp, target != nil {
                if events.count < 4096, cost + 64 <= 1_114_112 {
                    queuedKeys.remove(event.keyCode); events.append(event); cost += 64; schedule()
                } else { report("Typing is still waiting for the shell; the input buffer is full. Review the terminal before continuing.") }
                return true
            }
            guard event.type == .keyDown, !event.isARepeat else { return false }
            if target != nil { lastReady = nil; schedule(); return false }
            if let firstInterrupt, (0...3).contains(event.timestamp - firstInterrupt), let candidate, candidate.ownsInput() {
                self.firstInterrupt = nil; target = candidate; self.candidate = nil; generation = UUID(); schedule()
                queuedKeys.insert(event.keyCode)
            } else {
                let captured = capture()
                firstInterrupt = event.timestamp; candidate = captured
            }
            return false
        }
        if event.type == .keyDown { firstInterrupt = nil; candidate = nil }
        guard !flags.contains(.command), let target else { return false }
        guard target.ownsInput() else { cancel(); return false }
        if event.type == .keyUp, !queuedKeys.contains(event.keyCode) { return false }
        let amount = (event.characters?.utf8.count ?? 0) + 64
        guard events.count < 4096, cost + amount <= 1_114_112 else {
            report("Typing is still waiting for the shell; the input buffer is full. Review the terminal before continuing.")
            return true
        }
        if event.type == .keyDown { queuedKeys.insert(event.keyCode) }
        else { queuedKeys.remove(event.keyCode) }
        events.append(event); cost += amount; schedule()
        return true
    }

    func cancel() {
        let hadInput = !events.isEmpty
        firstInterrupt = nil; candidate = nil; target = nil; events.removeAll(); queuedKeys.removeAll(); cost = 0
        generation = UUID(); work?.cancel(); work = nil; inFlight = false; lastReady = nil
        if hadInput { report("The terminal input owner changed. Buffered typing was not sent to another terminal; please re-enter it in the intended shell.") }
    }

    private func schedule() {
        guard let target, work == nil, !inFlight else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, let target = self.target else { return }
            self.work = nil
            guard target.ownsInput() else { self.cancel(); return }
            self.inFlight = true
            target.probe { [weak self] status in
                guard let self, self.generation == token else { return }
                self.inFlight = false
                guard target.ownsInput() else { self.cancel(); return }
                switch status {
                case .waiting: self.lastReady = nil; self.schedule()
                case .changed: self.cancel()
                case .ready(let identity):
                    guard self.lastReady == identity else { self.lastReady = identity; self.schedule(); return }
                    target.prepare()
                    let pending = self.events
                    self.target = nil; self.events.removeAll(); self.queuedKeys.removeAll(); self.cost = 0; self.lastReady = nil
                    self.isReplaying = true
                    defer { self.isReplaying = false; target.didReplay() }
                    for event in pending {
                        guard self.generation == token, target.ownsInput() else {
                            self.report("The terminal input owner changed before buffered typing finished. Remaining input was not sent.")
                            return
                        }
                        self.replay(event)
                    }
                }
            }
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + target.pollInterval, execute: work)
    }
}
