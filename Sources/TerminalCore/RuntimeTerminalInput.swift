import Foundation

extension TerminalRuntime {
    func terminalInputBinding(paneID: String, expectedPID: Int32? = nil, generation: String? = nil, snapshot: RuntimeState) throws -> TerminalInputBinding {
        guard let pane = snapshot.sessions.first(where: { $0.id == paneID }), pane.pid > 1,
              expectedPID == nil || pane.pid == expectedPID else { throw TerminalError.invalid("Terminal input destination changed") }
        let launch = snapshot.agentLaunches.first { $0.paneID == paneID && $0.lifecycle == .active }
        if let generation, launch?.id != generation { throw TerminalError.invalid("Managed agent changed; review queued input") }
        return TerminalInputBinding(paneID: paneID, backendPID: pane.pid,
            generation: launch?.id ?? "terminal:\(pane.pid)", providerPID: launch?.providerPID)
    }

    public func terminalInputReadiness(paneID: String, generation: String) throws -> TerminalInputReadiness {
        try transaction {
            let snapshot = try state()
            guard snapshot.sessions.contains(where: { $0.id == paneID && $0.remote == nil }),
                  let binding = try? terminalInputBinding(paneID: paneID, generation: generation, snapshot: snapshot) else { return .changed }
            return try TerminalInputLedgerStore(root: root).load().readiness(binding: binding)
        }
    }

    public func markTerminalInputUncertain(paneID: String, expectedPID: Int32? = nil, expectedBinding: TerminalInputBinding? = nil) throws {
        try transaction {
            let binding = try terminalInputBinding(paneID: paneID, expectedPID: expectedPID, snapshot: state())
            guard expectedBinding == nil || expectedBinding == binding else { throw TerminalError.invalid("Terminal input owner changed") }
            let store = TerminalInputLedgerStore(root: root)
            var ledger = try store.load(); try ledger.markUncertain(binding: binding); try store.save(ledger)
        }
    }

    public func reviewTerminalInput(paneID: String, generation: String) throws {
        try transaction {
            let binding = try terminalInputBinding(paneID: paneID, generation: generation, snapshot: state())
            let store = TerminalInputLedgerStore(root: root)
            var ledger = try store.load(); try ledger.review(binding: binding); try store.save(ledger)
        }
    }

    func observeTerminalInputSubmit(paneID: String, generation: String, originStartedAt: Date) throws {
        try transaction {
            let binding = try terminalInputBinding(paneID: paneID, generation: generation, snapshot: state())
            let store = TerminalInputLedgerStore(root: root)
            var ledger = try store.load()
            ledger.observeTrustedSubmit(binding: binding, originStartedAt: originStartedAt)
            try store.save(ledger)
        }
    }

    public func deliverTerminalInput(paneID: String, expectedPID: Int32, expectedBinding: TerminalInputBinding? = nil, bytes: [UInt8],
                                    segments: [TerminalUserInputSegment], write: @escaping TerminalInputRelay.Writer,
                                    completion: @escaping TerminalInputRelay.Completion) {
        let key = root.path + "\u{0}" + paneID
        if let expectedBinding, !segments.contains(where: \.submissionCandidate),
           let stamp = TerminalInputFastPath.stamp(root: root), TerminalInputFastPath.shared.matches(key, expectedBinding, stamp) {
            write(bytes) { result in
                guard case .success(let count) = result, count == bytes.count else { completion(result); return }
                if TerminalInputFastPath.stamp(root: self.root) == stamp { completion(result); return }
                // State moved while the bytes were in flight, so record them the slow way.
                do {
                    try self.transaction {
                        let binding = try self.terminalInputBinding(paneID: paneID, expectedPID: expectedPID, snapshot: self.state())
                        guard binding == expectedBinding else { throw TerminalError.invalid("Terminal input ownership changed during delivery") }
                        let store = TerminalInputLedgerStore(root: self.root)
                        var ledger = try store.load()
                        let receipt = try ledger.beginManualWrite(binding: binding)
                        ledger.finishWrite(receipt, succeeded: true)
                        try store.save(ledger)
                        TerminalInputFastPath.shared.remember(key, binding, ledger: ledger, root: self.root)
                    }
                    completion(result)
                } catch { TerminalInputFastPath.shared.forget(key); completion(.failure(error)) }
            }
            return
        }
        do {
            try transaction {
                let binding = try terminalInputBinding(paneID: paneID, expectedPID: expectedPID, snapshot: state())
                guard expectedBinding == nil || expectedBinding == binding else { throw TerminalError.invalid("Terminal input owner changed before delivery") }
                let store = TerminalInputLedgerStore(root: root)
                var ledger = try store.load()
                var receipts: [TerminalInputWriteReceipt] = []
                for segment in segments where segment.mutatesInput {
                    receipts.append(try ledger.beginManualWrite(binding: binding, submissionCandidate: segment.submissionCandidate))
                }
                if receipts.isEmpty { receipts.append(try ledger.beginProtocolWrite(binding: binding)) }
                try store.save(ledger)
                let reserved = receipts
                write(bytes) { result in
                    do {
                        try self.transaction {
                            var latest = try store.load()
                            let succeeded: Bool
                            if case .success(let count) = result { succeeded = count == bytes.count } else { succeeded = false }
                            var matched = true
                            for receipt in reserved { if !latest.finishWrite(receipt, succeeded: succeeded) { matched = false } }
                            try store.save(latest)
                            guard matched else { throw TerminalError.invalid("Terminal input ownership changed during delivery") }
                            if succeeded { TerminalInputFastPath.shared.remember(key, binding, ledger: latest, root: self.root) }
                            else { TerminalInputFastPath.shared.forget(key) }
                        }
                        completion(result)
                    } catch { completion(.failure(error)) }
                }
            }
        } catch { completion(.failure(error)) }
    }

    func withTerminalAutomaticInputLease<T>(_ lease: TerminalInputLease, _ write: () throws -> T) throws -> T {
        try transaction {
            let snapshot = try state()
            let binding = try terminalInputBinding(paneID: lease.binding.paneID, expectedPID: lease.binding.backendPID,
                generation: lease.binding.generation, snapshot: snapshot)
            guard binding == lease.binding, snapshot.sessions.first(where: { $0.id == binding.paneID })?.remote == nil else {
                throw TerminalError.invalid("Terminal input destination changed; review queued input")
            }
            let store = TerminalInputLedgerStore(root: root)
            var ledger = try store.load()
            let receipt = try ledger.beginAutomaticWrite(lease)
            try store.save(ledger)
            do {
                let result = try write()
                ledger.finishWrite(receipt, succeeded: true); try store.save(ledger)
                return result
            } catch {
                ledger.finishWrite(receipt, succeeded: false); try? store.save(ledger)
                throw error
            }
        }
    }
}

// Typing held the shared runtime lock and synced the ledger twice per key. A pane whose ledger record
// already says "unconfirmed manual input" gains nothing from another entry, so those keys skip both
// while the state and ledger files are the ones that record was read from.
final class TerminalInputFastPath: @unchecked Sendable {
    struct Stamp: Equatable { let files: [[Int64]] }
    static let shared = TerminalInputFastPath()
    private let lock = NSLock()
    private var entries: [String: (binding: TerminalInputBinding, stamp: Stamp)] = [:]

    static func stamp(root: URL) -> Stamp? {
        var files: [[Int64]] = []
        for name in ["state.json", "continuity.json", "input-state/terminal-input.json"] {
            var info = stat()
            guard lstat(root.appendingPathComponent(name).path, &info) == 0 else {
                guard errno == ENOENT, name == "continuity.json" else { return nil }
                files.append([]); continue
            }
            files.append([Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size),
                          Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)])
        }
        return Stamp(files: files)
    }

    func matches(_ key: String, _ binding: TerminalInputBinding, _ stamp: Stamp) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return false }
        return entry.binding == binding && entry.stamp == stamp
    }

    // Call inside the runtime transaction, after the ledger is saved.
    func remember(_ key: String, _ binding: TerminalInputBinding, ledger: TerminalInputLedger, root: URL) {
        let stamp = ledger.manualInputAlreadyUnconfirmed(binding: binding) ? Self.stamp(root: root) : nil
        lock.lock(); defer { lock.unlock() }
        if let stamp { entries[key] = (binding, stamp) } else { entries[key] = nil }
    }

    func forget(_ key: String) { lock.lock(); entries[key] = nil; lock.unlock() }
}
