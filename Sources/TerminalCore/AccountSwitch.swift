import Foundation
import CryptoKit
import Darwin

public struct AccountSwitchPlan: Codable, Identifiable {
    public let id: String
    public let paneID: String
    public let provider: AgentKind
    public let expectedGeneration: String
    public let providerPID: Int32?
    public let sourceAccountID: String
    public let targetAccountID: String
    public let providerSessionID: String
    public let cwd: String
    public let sourceRoot: String
    public let targetRoot: String
    public let files: [String]
    public let createdAt: Date
}

public struct AccountTransferFile: Codable {
    public let path: String
    public let digest: String
    public let replaced: Bool
    public var previousDigest: String? = nil
}

public struct AccountTransferReceipt: Codable, Identifiable {
    public let id: String
    public let planID: String
    public let targetAccountID: String
    public var files: [AccountTransferFile]
    public var database: AccountDatabaseTransfer?
}

extension TerminalRuntime {
    public func prepareAccountSwitch(paneID: String, targetAccountID: String, expectedGeneration: String,
                                     toolsInFlight: Bool, safeTurnBoundary: Bool) throws -> AccountSwitchPlan {
        guard !toolsInFlight, safeTurnBoundary else { throw TerminalError.invalid("Wait for a safe turn boundary before switching accounts") }
        return try transaction {
            guard let launch = try state().agentLaunches.first(where: { $0.paneID == paneID && $0.id == expectedGeneration }),
                  let sourceID = launch.accountID, let sessionID = launch.providerSessionID, UUID(uuidString: sessionID) != nil else {
                throw TerminalError.invalid("No current managed conversation is available to switch")
            }
            let source = try accountRoot(sourceID), target = try accountRoot(targetAccountID)
            let files = try AccountSessionFiles.discover(provider: launch.provider, sessionID: sessionID, cwd: launch.cwd, root: source)
            let plan = AccountSwitchPlan(id: UUID().uuidString.lowercased(), paneID: paneID, provider: launch.provider,
                                         expectedGeneration: expectedGeneration, providerPID: launch.providerPID,
                                         sourceAccountID: sourceID, targetAccountID: targetAccountID, providerSessionID: sessionID,
                                         cwd: launch.cwd, sourceRoot: source.path, targetRoot: target.path, files: files, createdAt: Date())
            try validateAccountSwitch(plan)
            return plan
        }
    }

    public func validateAccountSwitch(_ plan: AccountSwitchPlan) throws {
        try transaction {
            let state = try state()
            guard UUID(uuidString: plan.id) != nil, UUID(uuidString: plan.providerSessionID) != nil,
                  Date().timeIntervalSince(plan.createdAt) >= -5, Date().timeIntervalSince(plan.createdAt) < 120,
                  let launch = state.agentLaunches.first(where: { $0.id == plan.expectedGeneration && $0.paneID == plan.paneID }),
                  launch.lifecycle == .active, launch.provider == plan.provider, launch.providerPID == plan.providerPID,
                  launch.bootID == (try Self.bootIdentity()),
                  launch.providerSessionID == plan.providerSessionID, launch.accountID == plan.sourceAccountID,
                  launch.configurationRoot == plan.sourceRoot, launch.cwd == plan.cwd,
                  let target = state.accounts.first(where: { $0.id == plan.targetAccountID }), target.enabled,
                  target.provider == plan.provider, target.id != plan.sourceAccountID,
                  (target.unavailableUntil ?? .distantPast) <= Date(),
                  try accountRoot(plan.sourceAccountID).path == plan.sourceRoot,
                  try accountRoot(plan.targetAccountID).path == plan.targetRoot else {
                throw TerminalError.invalid("Account switch became stale; refresh the conversation and target account")
            }
            guard !state.agentLaunches.contains(where: {
                $0.id != plan.expectedGeneration && [plan.sourceAccountID, plan.targetAccountID].contains($0.accountID ?? "") &&
                $0.providerSessionID == plan.providerSessionID && $0.lifecycle == .active
            }) else { throw TerminalError.invalid("Another pane already has this conversation open in the source or target account") }
        }
    }

    public func transferAccountSession(_ plan: AccountSwitchPlan) throws -> AccountTransferReceipt {
        try transaction {
            try validateAccountSwitch(plan)
            if let pid = plan.providerPID, pid > 0, kill(pid, 0) == 0 { throw TerminalError.invalid("Stop the old provider before transferring its conversation") }
            let source = try accountRoot(plan.sourceAccountID), target = try accountRoot(plan.targetAccountID)
            let files = try AccountSessionFiles.discover(provider: plan.provider, sessionID: plan.providerSessionID, cwd: plan.cwd, root: source)
            guard files == plan.files else { throw TerminalError.invalid("Conversation files changed; prepare the switch again") }
            let base = try ManagedDirectory.ensure(root, component: "account-transfers")
            let directory = try ManagedDirectory.ensure(base, component: plan.id)
            let receiptURL = directory.appendingPathComponent("receipt.json")
            guard !FileManager.default.fileExists(atPath: receiptURL.path) else { throw TerminalError.invalid("This switch has already been transferred") }
            var receipt = AccountTransferReceipt(id: plan.id, planID: plan.id, targetAccountID: plan.targetAccountID, files: [])
            do {
                for relative in files {
                    let data = try AccountFile.read(AccountSessionFiles.path(relative, beneath: source), limit: 64 * 1_048_576)
                    let destination = try AccountSessionFiles.path(relative, beneath: target, createParents: true)
                    let replaced = FileManager.default.fileExists(atPath: destination.path)
                    var previousDigest: String?
                    if replaced {
                        let old = try AccountFile.read(destination, limit: 64 * 1_048_576)
                        try Self.atomicWrite(old, to: AccountSessionFiles.path("backup/" + relative, beneath: directory, createParents: true))
                        previousDigest = AccountSessionFiles.digest(old)
                    }
                    receipt.files.append(AccountTransferFile(path: relative, digest: AccountSessionFiles.digest(data), replaced: replaced, previousDigest: previousDigest))
                    try Self.atomicWrite(JSONEncoder().encode(receipt), to: receiptURL)
                    try Self.atomicWrite(data, to: destination)
                }
                if plan.provider == .codex {
                    receipt.database = try AccountDatabaseTransfer.install(sessionID: plan.providerSessionID, source: source, target: target, rollout: files[0], backup: directory)
                    try Self.atomicWrite(JSONEncoder().encode(receipt), to: receiptURL)
                }
                return receipt
            } catch {
                try? rollbackAccountTransfer(receipt)
                throw error
            }
        }
    }

    public func rollbackAccountTransfer(_ receipt: AccountTransferReceipt) throws {
        try transaction {
            let (directory, saved) = try accountTransferReceipt(receipt)
            let target = try accountRollbackRoot(saved.targetAccountID)
            guard Set(saved.files.map(\.path)).count == saved.files.count else { throw TerminalError.invalid("Duplicate account rollback files") }
            var restores: [(destination: URL, previous: Data?, present: Bool)] = []
            for item in saved.files {
                let destination = try AccountSessionFiles.path(item.path, beneath: target)
                let old = item.replaced ? try AccountFile.read(AccountSessionFiles.path("backup/" + item.path, beneath: directory), limit: 64 * 1_048_576) : nil
                let previous = old.map(AccountSessionFiles.digest)
                guard item.previousDigest == nil || item.previousDigest == previous else { throw TerminalError.invalid("Conversation backup changed") }
                let present = try AccountRollbackRows.exists(destination)
                if present {
                    let current = try AccountSessionFiles.digest(AccountFile.read(destination, limit: 64 * 1_048_576))
                    guard current == item.digest || current == previous else {
                        throw TerminalError.invalid("Conversation changed after switching; refusing to overwrite newer work")
                    }
                }
                restores.append((destination, old, present))
            }
            var database = saved.database
            let databaseReceipt = directory.appendingPathComponent("database-transfer.json")
            if database == nil, try AccountRollbackRows.exists(databaseReceipt) {
                database = try JSONDecoder().decode(AccountDatabaseTransfer.self, from: AccountFile.read(databaseReceipt, limit: 1_048_576))
            }
            if database == nil, try AccountRollbackRows.exists(directory.appendingPathComponent("history-previous.json")) || AccountRollbackRows.exists(directory.appendingPathComponent("history-transfer.json")) {
                throw TerminalError.invalid("Account transfer metadata receipt is missing")
            }
            let databaseRestore = try database?.prepareRollback(target: target, backup: directory)
            try databaseRestore?.apply()
            for restore in restores.reversed() {
                if let old = restore.previous {
                    try Self.atomicWrite(old, to: restore.destination)
                } else if restore.present { try FileManager.default.removeItem(at: restore.destination) }
            }
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func commitAccountTransfer(_ receipt: AccountTransferReceipt) throws {
        try transaction {
            let (directory, _) = try accountTransferReceipt(receipt)
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func accountTransferReceipt(_ receipt: AccountTransferReceipt) throws -> (URL, AccountTransferReceipt) {
        guard UUID(uuidString: receipt.id) != nil else { throw TerminalError.invalid("Invalid account transfer receipt") }
        let receiptURL = try AccountSessionFiles.path("account-transfers/" + receipt.id + "/receipt.json", beneath: root)
        let directory = receiptURL.deletingLastPathComponent()
        let saved = try JSONDecoder().decode(AccountTransferReceipt.self, from: AccountFile.read(receiptURL, limit: 1_048_576))
        guard saved.id == receipt.id, saved.planID == receipt.planID, saved.targetAccountID == receipt.targetAccountID else { throw TerminalError.invalid("Account transfer receipt changed") }
        return (directory, saved)
    }

    private func accountRollbackRoot(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, try state().accounts.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown account") }
        let marker = try AccountSessionFiles.path("accounts/" + id + "/.trano-account", beneath: root)
        guard try AccountFile.read(marker, limit: 64) == Data("trano-account-v1\n".utf8) else { throw TerminalError.invalid("Account directory is not owned by Trano") }
        return marker.deletingLastPathComponent()
    }
}

enum AccountSessionFiles {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func path(_ relative: String, beneath root: URL, createParents: Bool = false) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw TerminalError.invalid("Invalid conversation path")
        }
        var directory = root
        for part in parts.dropLast() {
            if createParents { directory = try ManagedDirectory.ensure(directory, component: part) }
            else {
                directory.appendPathComponent(part)
                let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                    throw TerminalError.invalid("Conversation directories must be owned and cannot be symlinks")
                }
            }
        }
        return directory.appendingPathComponent(parts.last!)
    }

    static func discover(provider: AgentKind, sessionID: String, cwd: String, root: URL) throws -> [String] {
        guard let resolved = realpath(root.path, nil) else { throw TerminalError.invalid("Account directory is missing") }
        let canonicalRoot = String(cString: resolved)
        free(resolved)
        let prefix = provider == .claude ? "projects" : "sessions"
        let base = try path(prefix + "/.probe", beneath: root).deletingLastPathComponent()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
            throw TerminalError.invalid("No saved conversation exists for this account")
        }
        var matches: [URL] = [], visited = 0
        for case let url as URL in walker {
            visited += 1
            guard visited <= 30_000 else { throw TerminalError.invalid("Conversation search exceeds the bounded scan limit") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let filename = url.lastPathComponent
            let match = provider == .claude ? filename == sessionID + ".jsonl" : filename.hasPrefix("rollout-") && filename.hasSuffix("-" + sessionID + ".jsonl")
            if match { matches.append(url) }
        }
        guard matches.count == 1 else { throw TerminalError.invalid("Expected exactly one saved conversation with the verified session ID") }
        let transcript = matches[0]
        guard transcript.path.hasPrefix(canonicalRoot + "/") else { throw TerminalError.invalid("Conversation is outside its account directory") }
        let relative = String(transcript.path.dropFirst(canonicalRoot.count + 1))
        let data = try AccountFile.read(path(relative, beneath: root), limit: 64 * 1_048_576)
        guard data.last == 10 else { throw TerminalError.invalid("Conversation is still being written or is incomplete") }
        var verified = false
        if provider == .codex {
            guard let line = data.split(separator: 10).first,
                  let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta", let meta = object["payload"] as? [String: Any],
                  meta["id"] as? String == sessionID, meta["cwd"] as? String == cwd else {
                throw TerminalError.invalid("Codex rollout identity does not match this conversation")
            }
            guard meta["account_scoped"] as? Bool != true, meta["attached_thread"] as? Bool != true,
                  meta["history_base"] == nil || meta["history_base"] is NSNull else {
                throw TerminalError.invalid("This Codex conversation is account-bound or has shared fork history and cannot be transferred safely")
            }
            if meta["history_mode"] as? String == "paginated",
               !FileManager.default.fileExists(atPath: root.appendingPathComponent("thread_history_1.sqlite").path) {
                throw TerminalError.invalid("Codex paginated conversation history is missing; keep the original account until its history is repaired")
            }
            verified = true
        } else {
            for line in data.split(separator: 10) {
                guard line.count <= 8 * 1_048_576 else { throw TerminalError.invalid("Conversation record exceeds limit") }
                let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                if object?["sessionId"] as? String == sessionID && object?["cwd"] as? String == cwd { verified = true; break }
            }
        }
        guard verified else { throw TerminalError.invalid("Saved conversation identity does not match this pane") }
        var result = [relative], total = data.count
        if provider == .claude {
            let ancillary = transcript.deletingPathExtension()
            if FileManager.default.fileExists(atPath: ancillary.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: ancillary.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      let files = FileManager.default.enumerator(at: ancillary, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { throw TerminalError.invalid("Invalid Claude session artifacts") }
                for case let file as URL in files {
                    let value = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                    guard value.isSymbolicLink != true else { throw TerminalError.invalid("Session artifacts contain a symlink") }
                    if value.isRegularFile == true {
                        total += value.fileSize ?? 0
                        guard total <= 256 * 1_048_576, result.count < 4096 else { throw TerminalError.invalid("Conversation transfer exceeds limit") }
                        guard file.path.hasPrefix(canonicalRoot + "/") else { throw TerminalError.invalid("Session artifact is outside its account directory") }
                        result.append(String(file.path.dropFirst(canonicalRoot.count + 1)))
                    }
                }
            }
        }
        return result.sorted()
    }
}
