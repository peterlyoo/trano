import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class TwinStore {
    public let root: URL
    private let maximumBytes = 1_048_576
    public init(root: URL) { self.root = root }

    public func load() throws -> TwinState {
        let directory = try openRoot(); defer { close(directory) }
        return try readState(in: directory)
    }

    private func readState(in directory: Int32) throws -> TwinState {
        guard let data = try readData(in: directory) else { return TwinState() }
        let state: TwinState
        do { state = try JSONDecoder().decode(TwinState.self, from: data) }
        catch { throw TerminalError.invalid("Twin workflow state is invalid.") }
        try validate(state)
        return state
    }

    public func transaction<T>(_ body: (inout TwinState) throws -> T) throws -> T {
        let directory = try openRoot(); defer { close(directory) }
        let lease = try openLease("pessimistic-twins.lock", directory: directory); defer { close(lease) }
        while flock(lease, LOCK_EX) != 0 {
            guard errno == EINTR else { throw TerminalError.runtime("Cannot lock twin workflow state.") }
        }
        var state = try readState(in: directory)
        let previous = state
        let result = try body(&state)
        try validate(state)
        compactFinished(&state)
        if state != previous { try save(state, directory: directory) }
        return result
    }

    public func withOperationLease<T>(_ body: () throws -> T) throws -> T? {
        let directory = try openRoot(); defer { close(directory) }
        let lease = try openLease("pessimistic-twins-operation.lock", directory: directory); defer { close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw TerminalError.runtime("Cannot acquire twin workflow operation ownership.")
        }
        return try body()
    }

    private func openLease(_ name: String, directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot open twin workflow lease.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(descriptor); throw TerminalError.invalid("Twin workflow lease must be private and owned.")
        }
        return descriptor
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError.invalid("Twin workflow requires a private runtime directory.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor); throw TerminalError.invalid("Twin workflow requires a private owned runtime directory.")
        }
        return descriptor
    }

    private func readData(in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, "pessimistic-twins.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot open twin workflow state.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw TerminalError.invalid("Twin workflow state must be a private owned regular file of at most 1 MiB.")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read twin workflow state.") }
            if count == 0 { return result }
            guard result.count + count <= maximumBytes else { throw TerminalError.invalid("Twin workflow state exceeds 1 MiB.") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func save(_ state: TwinState, directory: Int32) throws {
        try validate(state)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(state); data.append(10)
        guard data.count <= maximumBytes else { throw TerminalError.invalid("Twin workflow state exceeds 1 MiB.") }
        let temporary = ".pessimistic-twins-write-" + UUID().uuidString.lowercased()
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.runtime("Cannot create twin workflow state.") }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("Cannot write twin workflow state.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, "pessimistic-twins.json") == 0 else {
            throw TerminalError.runtime("Cannot replace twin workflow state.")
        }
    }

    private func compactFinished(_ state: inout TwinState) {
        let history = state.runs.filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }
        var removed = Set(history.dropFirst(16).map(\.id))
        func removeArchived() {
            state.runs.removeAll { removed.contains($0.id) }
            state.decisionBindings.removeAll { removed.contains($0.runID) }
            state.forwardReceipts.removeAll { removed.contains($0.runID) }
        }
        removeArchived()
        for run in history.reversed() where !removed.contains(run.id) {
            guard (try? JSONEncoder().encode(state).count).map({ $0 > maximumBytes - 1 }) == true else { break }
            removed.insert(run.id); removeArchived()
        }
    }

    public static func validateSource(_ source: TwinSourceBinding) throws {
        guard uuid(source.paneID), uuid(source.generation), uuid(source.conversationID), source.provider != .shell,
              path(source.cwd), path(source.configurationRoot), text(source.accountID, limit: 512),
              process(source.backendIdentity, pid: source.backendPID), process(source.providerIdentity, pid: source.providerPID),
              source.backendPID != source.providerPID else { throw TerminalError.invalid("Invalid original twin session identity") }
    }

    private func validate(_ state: TwinState) throws {
        let active = state.runs.filter(\.isActive)
        guard state.schemaVersion == 1, state.runs.count <= 20, active.count <= 4,
              Set(state.runs.map(\.id)).count == state.runs.count,
              Set(active.map { $0.source.paneID }).count == active.count,
              state.decisionBindings.count <= 160, state.forwardReceipts.count <= 160,
              Set(state.decisionBindings.map(\.decisionID)).count == state.decisionBindings.count,
              Set(state.forwardReceipts.map(\.key)).count == state.forwardReceipts.count else { throw TerminalError.invalid("Invalid twin state bounds or duplicate ownership") }
        for run in state.runs {
            try Self.validateSource(run.source)
            guard Self.uuid(run.id), (1...8).contains(run.roundCap), (1...8).contains(run.noopCap),
                  run.rounds.count <= run.roundCap, Self.date(run.createdAt), Self.date(run.updatedAt),
                  Self.text(run.message, limit: 4096), Self.text(run.enabledCompletionID, limit: 512),
                  run.phase != .finished || run.exitReason != nil && run.operation == nil else { throw TerminalError.invalid("Invalid twin lifecycle") }
            if let operation = run.operation {
                guard Self.uuid(operation.id), (1...run.roundCap).contains(operation.round), Self.date(operation.startedAt),
                      run.rounds.contains(where: { $0.number == operation.round }) else { throw TerminalError.invalid("Invalid twin operation intent") }
            }
            for (index, round) in run.rounds.enumerated() {
                guard round.number == index + 1, Self.date(round.createdAt), Self.date(round.updatedAt),
                      Self.text(round.message, limit: 4096), Self.text(round.forwardedID, limit: 512),
                      Self.text(round.lastSourceCompletionID, limit: 512) else { throw TerminalError.invalid("Invalid twin round") }
                if let report = round.report { try report.validate() }
                if let report = round.sourceResponse { try report.validate() }
                for completion in [round.sourceCompletion, round.reviewCompletion, round.responseCompletion].compactMap({ $0 }) {
                    guard Self.completion(completion) else { throw TerminalError.invalid("Invalid trusted twin completion") }
                }
                if let snapshot = round.snapshot {
                    guard snapshot.runID == run.id, snapshot.round == round.number,
                          snapshot.sourceCWD == run.source.cwd,
                          [snapshot.repositoryRoot, snapshot.sourceCWD, snapshot.sourceGitDirectory, snapshot.commonDirectory, snapshot.worktreePath,
                           snapshot.ownership.path, snapshot.ownership.commonDirectory, snapshot.ownership.adminDirectory].allSatisfy(Self.path),
                          snapshot.worktreePath == snapshot.ownership.path, snapshot.commonDirectory == snapshot.ownership.commonDirectory,
                          snapshot.worktreePath != snapshot.repositoryRoot,
                          [snapshot.sourceHEAD, snapshot.sourceTree, snapshot.snapshotCommit].allSatisfy(Self.oid),
                          snapshot.sourceIndexSHA256.utf8.count == 64, Self.hex(snapshot.sourceIndexSHA256),
                          snapshot.sourceBranch.hasPrefix("refs/heads/"), snapshot.twinBranch.hasPrefix("refs/heads/"), snapshot.sourceBranch != snapshot.twinBranch,
                          Self.text(snapshot.sourceBranch, limit: 512), Self.text(snapshot.twinBranch, limit: 512) else { throw TerminalError.invalid("Invalid owned twin snapshot") }
                }
                if let pane = round.pane {
                    guard Self.uuid(pane.paneID), Self.uuid(pane.generation), Self.process(pane.backendIdentity, pid: pane.backendPID),
                          pane.paneID != run.source.paneID, pane.conversationID.map({ Self.uuid($0) && $0 != run.source.conversationID }) ?? true else { throw TerminalError.invalid("Twin pane must be a distinct fork") }
                }
                for oid in [round.tip, round.mergedCommit].compactMap({ $0 }) { guard Self.oid(oid) else { throw TerminalError.invalid("Invalid twin commit") } }
                if let decisionID = round.decisionID {
                    guard decisionID == TwinDecisionID.make(runID: run.id, round: round.number),
                          let binding = state.decisionBinding(id: decisionID), binding.runID == run.id, binding.round == round.number,
                          binding.sourceGeneration == run.source.generation, binding.snapshotOID == round.snapshot?.snapshotCommit,
                          binding.twinTipOID == round.tip else { throw TerminalError.invalid("Twin decision lost its protected binding") }
                }
                if let consent = round.consent {
                    guard consent.decisionID == round.decisionID, consent.twinTip == round.tip, Self.date(consent.chosenAt),
                          Self.text(consent.sourceCompletionID, limit: 512) else { throw TerminalError.invalid("Twin consent changed its reviewed tip") }
                }
                if let at = round.reportedAt { guard Self.date(at) else { throw TerminalError.invalid("Invalid twin report receipt date") } }
                guard Self.text(round.reportedTurnID, limit: 512) else { throw TerminalError.invalid("Invalid twin report turn identity") }
                if let at = round.sourceResponseAt { guard Self.date(at) else { throw TerminalError.invalid("Invalid twin source response date") } }
                if run.phase == .finished, (round.snapshot != nil || round.pane != nil) && !round.cleaned { throw TerminalError.invalid("Finished twin retains active resources") }
            }
        }
        for binding in state.decisionBindings {
            guard TwinDecisionID.isReserved(binding.decisionID), Self.uuid(binding.runID), (1...8).contains(binding.round),
                  Self.uuid(binding.sourceGeneration), Self.oid(binding.snapshotOID), Self.oid(binding.twinTipOID),
                  binding.decisionID == TwinDecisionID.make(runID: binding.runID, round: binding.round) else { throw TerminalError.invalid("Invalid twin decision association") }
        }
        for receipt in state.forwardReceipts {
            guard Self.uuid(receipt.runID), (1...8).contains(receipt.round), Self.uuid(receipt.paneID), Self.uuid(receipt.generation),
                  !receipt.inputID.isEmpty, receipt.inputID.utf8.count <= 512,
                  receipt.key == "twin:\(receipt.runID):\(receipt.round)", Self.date(receipt.createdAt) else { throw TerminalError.invalid("Invalid twin forwarding receipt") }
        }
    }

    private static func uuid(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    private static func date(_ value: Date) -> Bool { value.timeIntervalSince1970.isFinite }
    private static func text(_ value: String?, limit: Int) -> Bool { value.map { !$0.utf8.contains(0) && $0.utf8.count <= limit } ?? true }
    private static func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.utf8.contains(0) && value.utf8.count <= 4096 }
    private static func hex(_ value: String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func oid(_ value: String) -> Bool { (value.utf8.count == 40 || value.utf8.count == 64) && hex(value) }
    private static func process(_ value: SupervisorProcessIdentity, pid: Int32) -> Bool {
        pid > 1 && value.pid == pid && value.ownerUID == getuid() && value.startedAtSeconds > 0 && value.startedAtMicroseconds < 1_000_000
    }
    private static func completion(_ value: TwinCompletion) -> Bool {
        !value.id.isEmpty && !value.turnID.isEmpty && text(value.id, limit: 512) && text(value.turnID, limit: 512) && date(value.completedAt)
    }
}
