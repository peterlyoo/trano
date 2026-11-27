import Foundation
import Darwin

public enum FollowUpStatus: String, Codable { case pending, sending, needsReview }

public struct FollowUpInput: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public let paneID: String
    public var text: String
    public var generation: String?
    public var status: FollowUpStatus = .pending
    public var message: String?
    public var createdAt = Date()
    public var updatedAt = Date()
}

public struct FollowUpTurn: Codable, Equatable {
    public let paneID: String
    public let generation: String
    public var completionID: String?
    public var consumedCompletionID: String?
    var promptID: String?
    var armed = false
    var blocked = false
    var completionOriginPID: Int32?
    var completedAt: Date?
    var providerPID: Int32?
    var providerIdentity: String?

    public init(paneID: String, generation: String) { self.paneID = paneID; self.generation = generation }

    public mutating func observe(event: String, originPID: Int32) {
        switch event {
        case "UserPromptSubmit":
            promptID = UUID().uuidString.lowercased()
            armed = true; blocked = false; completionID = nil; completedAt = nil
        case "PermissionRequest": blocked = true; completionID = nil
        case "StopFailure", "SessionEnd", "SessionStart":
            armed = false; blocked = false; completionID = nil; completedAt = nil
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "PreModelRequest", "PostModelRequest":
            blocked = false; completionID = nil
        case "Stop":
            guard armed, !blocked, let promptID else { return }
            completionID = promptID; completionOriginPID = originPID; completedAt = Date(); armed = false
        default: break
        }
    }
}

public struct FollowUpPasteState: Codable, Equatable {
    public let paneID: String
    public let generation: String?
    public let backendPID: Int32
    public let providerPID: Int32?
    public let enabled: Bool
}

public struct FollowUpPasteScanner {
    private enum Mode { case ground, escape, csi, osc, oscEscape, string, stringEscape }
    private var mode = Mode.ground
    private var parameters: [UInt8] = []
    public init() {}

    public mutating func feed(_ data: Data) -> [Bool] {
        var changes: [Bool] = []
        for byte in data {
            switch mode {
            case .ground:
                if byte == 27 { mode = .escape }
            case .escape:
                switch byte {
                case 91: parameters.removeAll(keepingCapacity: true); mode = .csi
                case 93: mode = .osc
                case 80, 88, 94, 95: mode = .string
                case 99: changes.append(false); mode = .ground
                case 27: break
                default: mode = .ground
                }
            case .csi:
                if byte == 27 { parameters.removeAll(keepingCapacity: true); mode = .escape }
                else if (0x40...0x7e).contains(byte) {
                    if [104, 108].contains(byte), parameters.first == 63 {
                        let values = parameters.dropFirst().split(separator: 59, omittingEmptySubsequences: false)
                        if values.contains(where: { Array($0) == [50, 48, 48, 52] }) { changes.append(byte == 104) }
                    }
                    parameters.removeAll(keepingCapacity: true); mode = .ground
                } else if (0x20...0x3f).contains(byte), parameters.count < 64 { parameters.append(byte) }
                else { parameters.removeAll(keepingCapacity: true); mode = .ground }
            case .osc:
                if byte == 7 { mode = .ground }
                else if byte == 27 { mode = .oscEscape }
            case .oscEscape:
                if byte == 92 || byte == 7 { mode = .ground }
                else if byte != 27 { mode = .osc }
            case .string:
                if byte == 27 { mode = .stringEscape }
            case .stringEscape:
                if byte == 92 { mode = .ground }
                else if byte != 27 { mode = .string }
            }
        }
        return changes
    }
}

extension RuntimeState {
    mutating func invalidateFollowUps(paneID: String, message: String) {
        for index in followUpInputs.indices where followUpInputs[index].paneID == paneID {
            followUpInputs[index].status = .needsReview
            followUpInputs[index].message = message
            followUpInputs[index].updatedAt = Date()
        }
    }
}

private struct FollowUpProcess {
    let pid: Int32
    let parent: Int32
    let group: Int32
    let foregroundGroup: Int32
    let terminalDevice: UInt32
    let identity: String
    let startedAt: Date

    static func read(_ pid: Int32) -> FollowUpProcess? {
        guard pid > 1, kill(pid, 0) == 0 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard executable.hasPrefix("/") else { return nil }
        let identity = "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec):" + executable
        return FollowUpProcess(pid: pid, parent: Int32(info.pbi_ppid), group: Int32(info.pbi_pgid),
                               foregroundGroup: Int32(bitPattern: info.e_tpgid), terminalDevice: info.e_tdev, identity: identity,
                               startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000))
    }

    func descends(from ancestor: Int32) -> Bool {
        var current = pid
        var seen: Set<Int32> = []
        for _ in 0..<32 {
            if current == ancestor { return true }
            guard seen.insert(current).inserted, let process = Self.read(current) else { return false }
            current = process.parent
        }
        return false
    }
}

extension TerminalRuntime {
    private static func validateFollowUpText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || (127...159).contains($0.value) }) else {
            throw TerminalError.invalid("Enter nonblank text of at most 64 KiB without terminal controls; tabs and newlines are supported")
        }
    }

    private func followUpBinding(paneID: String, state: RuntimeState) throws -> (String?, String?) {
        guard let pane = state.sessions.first(where: { $0.id == paneID }) else { throw TerminalError.invalid("Unknown queued input pane") }
        guard pane.remote == nil else { return (nil, "Automatic delivery is unavailable for remote panes. Keep or delete this input; edit it after choosing a local managed agent.") }
        guard let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.lifecycle == .active }),
              launch.bootID == (try? Self.bootIdentity()), let pid = launch.processID, kill(pid, 0) == 0 else {
            return (nil, "Start a managed Claude or Codex agent in this pane, then edit this input to queue it.")
        }
        return (launch.id, nil)
    }

    private func ensureFollowUpMonitor(paneID: String, state: RuntimeState) throws {
        guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable),
              let pane = state.sessions.first(where: { $0.id == paneID && $0.remote == nil }),
              let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.lifecycle == .active }),
              pane.pid > 1 else { return }
        if state.followUpPasteStates.contains(where: { $0.paneID == paneID && $0.backendPID == pane.pid && $0.generation == launch.id }) { return }
        let marker = "\(pane.pid):1"
        if let existing = try host.pane(pane.id), existing.pipe, existing.options["@trano_followup_monitor"] == marker { return }
        let command = "exec /usr/bin/env " + ShellQuote.quote("TRANO_DATA_DIR=" + root.path) + " " + ShellQuote.quote(helperExecutable) + " monitor " + ShellQuote.quote(pane.id) + " " + String(pane.pid)
        try host.pipe(pane.id, command: command)
        try host.setOption(pane.id, key: "@trano_followup_monitor", value: marker)
    }

    public func followUps(paneID: String) throws -> [FollowUpInput] {
        try transaction {
            let snapshot = try state()
            guard snapshot.sessions.contains(where: { $0.id == paneID }) else { throw TerminalError.invalid("Unknown queued input pane") }
            return snapshot.followUpInputs.filter { $0.paneID == paneID }
        }
    }

    @discardableResult public func addFollowUp(paneID: String, text: String) throws -> FollowUpInput {
        try addFollowUp(paneID: paneID, text: text, insertionID: nil)
    }

    @discardableResult func addFollowUp(paneID: String, text: String, insertionID: String?) throws -> FollowUpInput {
        try Self.validateFollowUpText(text)
        return try transaction {
            let snapshot = try state()
            guard snapshot.followUpInputs.filter({ $0.paneID == paneID }).count < 100 else { throw TerminalError.invalid("A pane can hold at most 100 queued inputs") }
            let (generation, message) = try followUpBinding(paneID: paneID, state: snapshot)
            try ensureFollowUpMonitor(paneID: paneID, state: snapshot)
            var input = FollowUpInput(paneID: paneID, text: text, generation: generation)
            if let insertionID {
                guard UUID(uuidString: insertionID) != nil, !snapshot.followUpInputs.contains(where: { $0.id == insertionID }) else { throw TerminalError.invalid("Queued input receipt already exists") }
                input.id = insertionID
            }
            input.message = message; input.status = message == nil ? .pending : .needsReview
            try update { $0.followUpInputs.append(input) }
            return input
        }
    }

    @discardableResult public func updateFollowUp(id: String, text: String) throws -> FollowUpInput {
        try Self.validateFollowUpText(text)
        return try transaction {
            let snapshot = try state()
            guard let index = snapshot.followUpInputs.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown queued input") }
            guard snapshot.followUpInputs[index].status != .sending else { throw TerminalError.invalid("Delivery is in progress; wait before editing this input") }
            var input = snapshot.followUpInputs[index]
            let (generation, message) = try followUpBinding(paneID: input.paneID, state: snapshot)
            try ensureFollowUpMonitor(paneID: input.paneID, state: snapshot)
            input.text = text; input.generation = generation; input.message = message
            input.status = message == nil ? .pending : .needsReview; input.updatedAt = Date()
            try update { $0.followUpInputs[index] = input }
            return input
        }
    }

    public func removeFollowUp(id: String) throws {
        try update { state in
            guard let index = state.followUpInputs.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown queued input") }
            guard state.followUpInputs[index].status != .sending else { throw TerminalError.invalid("Delivery is in progress; wait before deleting this input") }
            state.followUpInputs.remove(at: index)
        }
    }

    func observeFollowUpHook(paneID: String, generation: String, event: String, originPID: Int32) throws {
        try update { state in
            guard let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.id == generation && $0.lifecycle == .active }),
                  let providerPID = launch.providerPID, let provider = FollowUpProcess.read(providerPID),
                  ProcessIdentity.isRootHook(originPID: originPID, providerPID: providerPID, provider: launch.provider) else { return }
            let existing = state.followUpTurns.firstIndex { $0.paneID == paneID && $0.generation == generation }
            guard existing != nil || event == "UserPromptSubmit" else { return }
            var turn = existing.map { state.followUpTurns[$0] } ?? FollowUpTurn(paneID: paneID, generation: generation)
            if event == "UserPromptSubmit" { turn.providerPID = providerPID; turn.providerIdentity = provider.identity }
            guard turn.providerPID == providerPID, turn.providerIdentity == provider.identity else { return }
            if event == "UserPromptSubmit", let origin = FollowUpProcess.read(originPID) {
                try observeTerminalInputSubmit(paneID: paneID, generation: generation, originStartedAt: origin.startedAt)
            }
            turn.observe(event: event, originPID: originPID)
            if let existing { state.followUpTurns[existing] = turn }
            else { state.followUpTurns.append(turn) }
        }
    }

    public func recordFollowUpPasteMode(paneID: String, expectedPID: Int32, enabled: Bool) throws {
        try transaction {
            let snapshot = try state()
            guard let pane = snapshot.sessions.first(where: { $0.id == paneID && $0.pid == expectedPID && $0.remote == nil }) else { return }
            let launch = snapshot.agentLaunches.first { $0.paneID == paneID && $0.lifecycle == .active }
            var accepted = false
            if enabled, let launch, let providerPID = launch.providerPID, let provider = FollowUpProcess.read(providerPID) {
                accepted = (try? validateFollowUpForeground(pane: pane, launch: launch, provider: provider)) != nil
            }
            let value = FollowUpPasteState(paneID: paneID, generation: launch?.id, backendPID: expectedPID,
                                          providerPID: launch?.providerPID, enabled: enabled && accepted)
            if snapshot.followUpPasteStates.first(where: { $0.paneID == paneID }) == value { return }
            try update { state in state.followUpPasteStates.removeAll { $0.paneID == paneID }; state.followUpPasteStates.append(value) }
        }
    }

    private func validateFollowUpForeground(pane: TerminalSession, launch: AgentLaunch, provider: FollowUpProcess) throws {
        guard launch.lifecycle == .active, launch.bootID == (try? Self.bootIdentity()), launch.providerPID == provider.pid,
              let supervisorPID = launch.processID, FollowUpProcess.read(supervisorPID) != nil,
              provider.descends(from: supervisorPID), provider.descends(from: pane.pid) else {
            throw TerminalError.runtime("The managed agent process identity changed. Edit the input after restarting the agent.")
        }
        guard let metadata = try host.pane(pane.id), metadata.pid == pane.pid, metadata.alive,
              metadata.tty.hasPrefix("/dev/") else { throw TerminalError.runtime("The terminal process changed. Edit the input to review its destination.") }
        let fd = open(metadata.tty, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot verify the agent's foreground terminal. Automatic delivery is paused.") }
        defer { close(fd) }
        var terminal = stat()
        guard fstat(fd, &terminal) == 0, terminal.st_mode & S_IFMT == S_IFCHR,
              provider.group == provider.pid,
              let current = FollowUpProcess.read(provider.pid), current.identity == provider.identity,
              current.foregroundGroup == provider.group, current.terminalDevice == UInt32(bitPattern: terminal.st_rdev),
              current.descends(from: pane.pid) else { throw TerminalError.runtime("The managed agent does not own the foreground terminal. Edit the input when it is ready.") }
    }

    public func processPendingFollowUps() throws {
        try transaction {
            var snapshot = try state()
            let before = snapshot.followUpInputs
            let boot = try Self.bootIdentity()
            for index in snapshot.followUpInputs.indices {
                let input = snapshot.followUpInputs[index]
                var message: String?
                if input.status == .sending { message = "The previous delivery was interrupted and may already have reached the agent. Review its conversation before editing this input to retry." }
                else if input.status == .pending {
                    if snapshot.sessions.first(where: { $0.id == input.paneID })?.remote != nil { message = "Automatic delivery is unavailable for remote panes. Edit this input after choosing a local managed agent." }
                    else if let launch = snapshot.agentLaunches.first(where: { $0.paneID == input.paneID && $0.id == input.generation && $0.lifecycle == .active }),
                            launch.bootID == boot, let pid = launch.processID, FollowUpProcess.read(pid) != nil {
                        if let providerPID = launch.providerPID, FollowUpProcess.read(providerPID) == nil { message = "The managed agent exited. Start an agent and edit this input to requeue it." }
                    } else { message = "The managed agent changed or exited. Start an agent and edit this input to requeue it." }
                }
                if let message {
                    snapshot.followUpInputs[index].status = .needsReview
                    snapshot.followUpInputs[index].message = message
                    snapshot.followUpInputs[index].updatedAt = Date()
                }
            }
            if snapshot.followUpInputs != before { try update { $0.followUpInputs = snapshot.followUpInputs } }
            for (turnIndex, turn) in snapshot.followUpTurns.enumerated() {
                guard let completion = turn.completionID, completion != turn.consumedCompletionID,
                      let completedAt = turn.completedAt, Date().timeIntervalSince(completedAt) >= 0.25,
                      let first = snapshot.followUpInputs.first(where: { $0.paneID == turn.paneID }),
                      first.status == .pending, first.generation == turn.generation, first.updatedAt <= completedAt,
                      let pane = snapshot.sessions.first(where: { $0.id == turn.paneID && $0.remote == nil }),
                      pane.activity.state == .done, pane.activity.source == "hook",
                      let launch = snapshot.agentLaunches.first(where: { $0.paneID == turn.paneID && $0.id == turn.generation && $0.lifecycle == .active }),
                      launch.providerPID == turn.providerPID, let providerPID = turn.providerPID,
                      let provider = FollowUpProcess.read(providerPID), provider.identity == turn.providerIdentity else { continue }
                let inputReadiness = try terminalInputReadiness(paneID: pane.id, generation: launch.id)
                guard let inputLease = inputReadiness.lease else {
                    if inputReadiness != .inputInFlight {
                        try holdFollowUp(first.id, message: "Terminal input changed or could not be verified. Review the pane, then choose Resume next turn and submit your next prompt manually. Queued input resumes after that turn finishes.")
                    }
                    continue
                }
                guard try decisionGateReason(paneID: pane.id, generation: launch.id) == nil else { continue }
                if let hookPID = turn.completionOriginPID, kill(hookPID, 0) == 0 { continue }
                guard snapshot.followUpPasteStates.contains(where: { $0.paneID == pane.id && $0.generation == launch.id && $0.backendPID == pane.pid && $0.providerPID == providerPID && $0.enabled }) else {
                    if Date().timeIntervalSince(completedAt) > 15 { try holdFollowUp(first.id, message: "The agent has not enabled verified safe paste. Enter one prompt manually, then edit this input to requeue it. If this continues, restart the managed agent before requeuing.") }
                    continue
                }
                do { try validateFollowUpForeground(pane: pane, launch: launch, provider: provider) }
                catch { try holdFollowUp(first.id, message: error.localizedDescription); continue }
                try update { state in
                    guard let index = state.followUpInputs.firstIndex(where: { $0.id == first.id }) else { return }
                    state.followUpInputs[index].status = .sending; state.followUpInputs[index].message = nil; state.followUpInputs[index].updatedAt = Date()
                    state.followUpTurns[turnIndex].consumedCompletionID = completion
                }
                do {
                    try validateFollowUpForeground(pane: pane, launch: launch, provider: provider)
                    try commitTerminalAutomaticInput(lease: inputLease, text: first.text)
                    try update { $0.followUpInputs.removeAll { $0.id == first.id } }
                } catch {
                    try holdFollowUp(first.id, message: "Delivery could not be confirmed and may have reached the agent. Review its conversation before editing this input to retry.")
                }
                return
            }
        }
    }

    public func commitTerminalAutomaticInput(lease: TerminalInputLease, text: String) throws {
        try Self.validateFollowUpText(text)
        try transaction {
            let snapshot = try state()
            let binding = lease.binding
            guard let pane = snapshot.sessions.first(where: { $0.id == binding.paneID && $0.pid == binding.backendPID && $0.remote == nil }),
                  let launch = snapshot.agentLaunches.first(where: { $0.paneID == pane.id && $0.id == binding.generation && $0.lifecycle == .active }),
                  let providerPID = launch.providerPID, providerPID == binding.providerPID,
                  let provider = FollowUpProcess.read(providerPID),
                  snapshot.followUpPasteStates.contains(where: { $0.paneID == pane.id && $0.generation == launch.id && $0.backendPID == pane.pid && $0.providerPID == providerPID && $0.enabled }),
                  try decisionGateReason(paneID: pane.id, generation: launch.id) == nil else {
                throw TerminalError.invalid("The managed agent is not ready for automatic input")
            }
            try validateFollowUpForeground(pane: pane, launch: launch, provider: provider)
            try withTerminalAutomaticInputLease(lease) {
                let paste = "\u{1b}[200~" + text + "\u{1b}[201~\r"
                try host.write(pane.id, Data(paste.utf8))
            }
        }
    }

    public func reviewFollowUp(id: String) throws {
        try transaction {
            let snapshot = try state()
            guard let input = snapshot.followUpInputs.first(where: { $0.id == id }), input.status == .needsReview else {
                throw TerminalError.invalid("Choose a queued input that requires review")
            }
            let (generation, message) = try followUpBinding(paneID: input.paneID, state: snapshot)
            guard let generation, message == nil else { throw TerminalError.invalid(message ?? "Start a managed agent before resuming the queue") }
            try reviewTerminalInput(paneID: input.paneID, generation: generation)
            try update { state in
                guard let index = state.followUpInputs.firstIndex(where: { $0.id == id && $0.status == .needsReview }) else { return }
                state.followUpInputs[index].generation = generation
                state.followUpInputs[index].status = .pending
                state.followUpInputs[index].message = "Submit your next prompt manually. Queued input resumes after that turn finishes."
                state.followUpInputs[index].updatedAt = Date()
            }
        }
    }

    private func holdFollowUp(_ id: String, message: String) throws {
        try update { state in
            guard let index = state.followUpInputs.firstIndex(where: { $0.id == id }) else { return }
            state.followUpInputs[index].status = .needsReview
            state.followUpInputs[index].message = message
            state.followUpInputs[index].updatedAt = Date()
        }
    }
}


extension TerminalRuntime {
    func forwardTwinResult(run: TwinRun, round: TwinRound, key: String) throws -> String {
        guard key == "twin:\(run.id):\(round.number)" else { throw TerminalError.invalid("The twin feedback identity does not match this round") }
        let inputID = TwinDecisionBridge.inputID(key: key)
        let text = try TwinDecisionBridge.feedback(run: run, round: round, executable: helperExecutable)
        return try transaction {
            let store = TwinStore(root: root), canonical = try store.load()
            guard let current = canonical.runs.first(where: { $0.id == run.id }), current.source == run.source,
                  let actualRound = current.rounds.first(where: { $0.number == round.number }), actualRound.report == round.report,
                  actualRound.consent == round.consent, actualRound.mergedCommit == round.mergedCommit else {
                throw TerminalError.invalid("The twin feedback no longer belongs to the reviewed source and outcome")
            }
            if let receipt = canonical.forwardReceipts.first(where: { $0.key == key }) {
                guard receipt.runID == run.id, receipt.round == round.number, receipt.inputID == inputID,
                      receipt.paneID == run.source.paneID, receipt.generation == run.source.generation else {
                    throw TerminalError.invalid("The durable twin feedback receipt belongs to another source")
                }
                return receipt.inputID
            }
            let context = try twinSourceContext(run: current)
            guard current == run, actualRound == round, current.phase == .forwarding, current.operation?.kind == .forward,
                  current.operation?.round == round.number, current.latestRound == actualRound,
                  context.enabled, context.source == current.source else {
                throw TerminalError.invalid("The original session or feedback operation changed before queuing")
            }
            let state = try self.state()
            if let existing = state.followUpInputs.first(where: { $0.id == inputID }) {
                guard existing.paneID == run.source.paneID, existing.generation == run.source.generation,
                      existing.text == text else { throw TerminalError.invalid("The queued twin feedback was edited or rebound; it will not be overwritten") }
            } else {
                let input = try addFollowUp(paneID: run.source.paneID, text: text, insertionID: inputID)
                guard input.generation == run.source.generation, input.status == .pending else {
                    throw TerminalError.invalid("The original agent changed while queuing its twin feedback")
                }
            }
            return try store.transaction { state in
                guard let exact = state.runs.first(where: { $0.id == run.id }), exact == current else {
                    throw TerminalError.invalid("The twin workflow changed after queuing; its receipt requires review")
                }
                if let receipt = state.forwardReceipts.first(where: { $0.key == key }) {
                    guard receipt.inputID == inputID, receipt.paneID == run.source.paneID, receipt.generation == run.source.generation else {
                        throw TerminalError.invalid("The twin feedback receipt changed during insertion")
                    }
                    return receipt.inputID
                }
                state.forwardReceipts.append(TwinForwardReceipt(key: key, runID: run.id, round: round.number,
                    paneID: run.source.paneID, generation: run.source.generation, inputID: inputID))
                return inputID
            }
        }
    }
}
