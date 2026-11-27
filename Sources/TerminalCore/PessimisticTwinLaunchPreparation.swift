import Foundation
import CryptoKit
import Darwin
import Security
import LocalAuthentication

public struct TwinLaunchTicket: Codable, Equatable {
    public let runID: String
    public let round: Int
    public let source: TwinSourceBinding
    public let sourceCompletion: TwinCompletion
    public let generation: String
    public let configurationRoot: String
    public let providerExecutable: String
    public let args: [String]
    public let environment: [String: String]
    public let removeEnvironment: [String]
    public let sourceOrganizationAuthorization: AccountOrganizationAuthorization?
    public let authenticationSeedProof: TwinAuthenticationSeedProof?
    public let sourceTranscriptSHA256: String?
    public let sourceTranscriptRelativePath: String?
    public var paneID: String?
    public var backendPID: Int32?
    public var backendIdentity: SupervisorProcessIdentity?
    public var inputFingerprint: String?
    public var reportedEnvelope: TwinReport?
    public var reportedAt: Date?
    public var reportedTurnID: String?
    public var providerExitCode: Int32?
    public var lastCompletion: TwinCompletion?
    public var lastInputFingerprint: String?
    public var mutationStages: [String]

    public init(runID: String, round: Int, source: TwinSourceBinding, sourceCompletion: TwinCompletion,
                generation: String = UUID().uuidString.lowercased(), configurationRoot: String, providerExecutable: String,
                args: [String], environment: [String: String], removeEnvironment: [String],
                sourceOrganizationAuthorization: AccountOrganizationAuthorization? = nil,
                authenticationSeedProof: TwinAuthenticationSeedProof? = nil, sourceTranscriptSHA256: String? = nil, sourceTranscriptRelativePath: String? = nil,
                paneID: String? = nil, backendPID: Int32? = nil, backendIdentity: SupervisorProcessIdentity? = nil,
                inputFingerprint: String? = nil, reportedEnvelope: TwinReport? = nil, reportedAt: Date? = nil,
                reportedTurnID: String? = nil, providerExitCode: Int32? = nil, lastCompletion: TwinCompletion? = nil,
                lastInputFingerprint: String? = nil, mutationStages: [String] = []) {
        self.runID = runID; self.round = round; self.source = source; self.sourceCompletion = sourceCompletion
        self.generation = generation; self.configurationRoot = configurationRoot; self.providerExecutable = providerExecutable
        self.args = args; self.environment = environment; self.removeEnvironment = removeEnvironment
        self.sourceOrganizationAuthorization = sourceOrganizationAuthorization
        self.authenticationSeedProof = authenticationSeedProof
        self.sourceTranscriptSHA256 = sourceTranscriptSHA256; self.sourceTranscriptRelativePath = sourceTranscriptRelativePath
        self.paneID = paneID; self.backendPID = backendPID; self.backendIdentity = backendIdentity
        self.inputFingerprint = inputFingerprint; self.reportedEnvelope = reportedEnvelope; self.reportedAt = reportedAt
        self.reportedTurnID = reportedTurnID; self.providerExitCode = providerExitCode; self.lastCompletion = lastCompletion
        self.lastInputFingerprint = lastInputFingerprint; self.mutationStages = mutationStages
    }

    func validate() throws {
        guard UUID(uuidString: runID) != nil, (1...8).contains(round), UUID(uuidString: generation) != nil,
              !sourceCompletion.id.isEmpty, !sourceCompletion.turnID.isEmpty,
              TwinProviderPlanner.validPath(configurationRoot), TwinProviderPlanner.validPath(providerExecutable),
              args.count <= 128, args.reduce(0, { $0 + $1.utf8.count }) <= 262_144,
              args.allSatisfy({ !$0.utf8.contains(0) }), environment.count <= 128, removeEnvironment.count <= 128,
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) && $0.value.utf8.count <= 65_536 }),
              mutationStages.count <= 128, mutationStages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }),
              (sourceTranscriptSHA256 == nil) == (sourceTranscriptRelativePath == nil),
              sourceTranscriptSHA256.map({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }) ?? true,
              (paneID == nil && backendPID == nil && backendIdentity == nil) ||
                (paneID.flatMap(UUID.init(uuidString:)) != nil && ((backendPID == nil && backendIdentity == nil) ||
                    ((backendPID ?? 0) > 1 && backendIdentity?.pid == backendPID && backendIdentity?.ownerUID == getuid()))) else {
            throw TerminalError.invalid("Invalid pessimistic twin launch ticket")
        }
        try authenticationSeedProof?.validate()
        try reportedEnvelope?.validate()
    }

    func hasSameLaunch(as other: Self) -> Bool {
        runID == other.runID && round == other.round && source == other.source && sourceCompletion == other.sourceCompletion
            && generation == other.generation && configurationRoot == other.configurationRoot && providerExecutable == other.providerExecutable
            && args == other.args && environment == other.environment && removeEnvironment == other.removeEnvironment
            && authenticationSeedProof == other.authenticationSeedProof
            && sourceOrganizationAuthorization == other.sourceOrganizationAuthorization
            && sourceTranscriptSHA256 == other.sourceTranscriptSHA256 && sourceTranscriptRelativePath == other.sourceTranscriptRelativePath
    }
}

private struct TwinLaunchTicketSettings: SettingsPreferences {
    var ticket: TwinLaunchTicket?
    init() {}
    func validate() throws { try ticket?.validate() }
}

public final class TwinLaunchTicketStore {
    private let root: URL
    private let runID: String
    private let round: Int
    public init(root: URL, runID: String, round: Int) throws {
        guard UUID(uuidString: runID) != nil, (1...8).contains(round) else { throw TerminalError.invalid("Invalid twin launch location") }
        self.root = root; self.runID = runID; self.round = round
    }
    public var directory: URL { root.appendingPathComponent("twins").appendingPathComponent(runID).appendingPathComponent("round-\(round)") }
    private func settings() throws -> SecureSettingsSidecar<TwinLaunchTicketSettings> {
        try TwinLaunchPreparationFiles.validateDirectory(directory.path, privateLeaf: true)
        return try SecureSettingsSidecar(root: directory, filename: "launch-ticket.json")
    }
    public func load() throws -> TwinLaunchTicket {
        guard let ticket = try settings().load().ticket else { throw TerminalError.invalid("The twin launch ticket is unavailable") }
        try validateLocation(ticket)
        return ticket
    }
    @discardableResult public func create(_ ticket: TwinLaunchTicket) throws -> TwinLaunchTicket {
        try validateLocation(ticket)
        _ = try settings().update { value in
            guard value.ticket == nil else { throw TerminalError.invalid("A twin launch ticket already exists; review the interrupted launch") }
            value.ticket = ticket
        }
        return ticket
    }
    @discardableResult public func update(_ mutation: (inout TwinLaunchTicket) throws -> Void) throws -> TwinLaunchTicket {
        var result: TwinLaunchTicket?
        _ = try settings().update { value in
            guard var ticket = value.ticket else { throw TerminalError.invalid("The twin launch ticket is unavailable") }
            let before = ticket
            try mutation(&ticket)
            guard ticket.hasSameLaunch(as: before), before.paneID == nil || ticket.paneID == before.paneID,
                  before.backendPID == nil || ticket.backendPID == before.backendPID,
                  before.backendIdentity == nil || ticket.backendIdentity == before.backendIdentity else {
                throw TerminalError.invalid("The twin launch identity cannot be replaced")
            }
            try validateLocation(ticket)
            value.ticket = ticket; result = ticket
        }
        return result!
    }
    private func validateLocation(_ ticket: TwinLaunchTicket) throws {
        try ticket.validate()
        guard ticket.runID == runID, ticket.round == round, ticket.configurationRoot == directory.appendingPathComponent("profile").path else {
            throw TerminalError.invalid("The twin launch ticket belongs to another location")
        }
    }
}

public struct TwinLaunchPreparationOperations {
    public var context: (TwinRun) throws -> TwinRuntimeContext
    public var snapshot: (TwinRun, TwinRound) throws -> TwinGitSnapshot
    public var executable: (TwinSourceBinding) throws -> String
    public var credentials: (TwinSourceBinding) throws -> [String: Data]
    public var authenticationSeed: ((TwinSourceBinding) throws -> TwinAuthenticationSeed)?
    public var selectedOrganizationUUID: (TwinSourceBinding, AccountOrganizationAuthorization?) throws -> String?
    public var conversation: (TwinSourceBinding, TwinReviewMode) throws -> TwinConversationSeed?
    public var organization: (TwinSourceBinding, String) throws -> AccountOrganizationAuthorization?
    public var revalidateOrganization: (AccountOrganizationAuthorization, TwinSourceBinding, String) throws -> Void
    public var scopedSocket: (String) throws -> String
    public var helperExecutable: String
    public var active: () -> Bool
    public init(context: @escaping (TwinRun) throws -> TwinRuntimeContext,
                snapshot: @escaping (TwinRun, TwinRound) throws -> TwinGitSnapshot,
                executable: @escaping (TwinSourceBinding) throws -> String,
                credentials: @escaping (TwinSourceBinding) throws -> [String: Data],
                conversation: @escaping (TwinSourceBinding, TwinReviewMode) throws -> TwinConversationSeed?,
                organization: @escaping (TwinSourceBinding, String) throws -> AccountOrganizationAuthorization?,
                revalidateOrganization: @escaping (AccountOrganizationAuthorization, TwinSourceBinding, String) throws -> Void,
                scopedSocket: @escaping (String) throws -> String, helperExecutable: String, active: @escaping () -> Bool = { true },
                authenticationSeed: ((TwinSourceBinding) throws -> TwinAuthenticationSeed)? = nil,
                selectedOrganizationUUID: @escaping (TwinSourceBinding, AccountOrganizationAuthorization?) throws -> String? = { _, _ in nil }) {
        self.authenticationSeed = authenticationSeed; self.selectedOrganizationUUID = selectedOrganizationUUID
        self.context = context; self.snapshot = snapshot; self.executable = executable; self.credentials = credentials
        self.conversation = conversation; self.organization = organization; self.revalidateOrganization = revalidateOrganization
        self.scopedSocket = scopedSocket; self.helperExecutable = helperExecutable; self.active = active
    }
}

public struct TwinLaunchPreparer {
    public let root: URL
    public let operations: TwinLaunchPreparationOperations
    public init(root: URL, operations: TwinLaunchPreparationOperations) { self.root = root; self.operations = operations }
    public func prepare(run: TwinRun, round: TwinRound) throws -> TwinGitSnapshot {
        guard let completion = round.sourceCompletion, round.number >= 1, round.number <= run.roundCap else {
            throw TerminalError.invalid("The source completion was not captured for this twin round")
        }
        let frozen = try current(run)
        guard frozen.ready, frozen.source == run.source, frozen.completion == completion else {
            throw TerminalError.invalid("The original done boundary changed before twin preparation")
        }
        let executable = try operations.executable(run.source)
        let authenticationWitness = try seed(run.source).sourceFingerprint
        let conversation = run.mode == .securityReview ? nil : try operations.conversation(run.source, run.mode)
        if let conversation { try TwinLaunchPreparationFiles.validateConversation(conversation, source: run.source) }
        else if run.mode != .securityReview { throw TerminalError.invalid("The exact source conversation could not be frozen") }
        try requireSame(run, frozen)
        let snapshot = try operations.snapshot(run, round)
        guard snapshot.runID == run.id, snapshot.round == round.number, snapshot.sourceCWD == run.source.cwd,
              snapshot.worktreePath == root.appendingPathComponent("twins").appendingPathComponent(run.id).appendingPathComponent("round-\(round.number)/worktree").path else {
            throw TerminalError.invalid("The twin snapshot belongs to another round or source")
        }
        try requireSame(run, frozen)
        let authorization = try operations.organization(run.source, snapshot.worktreePath)
        if let authorization {
            guard authorization.accountID == run.source.accountID, authorization.configurationRoot == run.source.configurationRoot else {
                throw TerminalError.invalid("The source organization proof belongs to another account")
            }
            try operations.revalidateOrganization(authorization, run.source, snapshot.worktreePath)
        } else if run.source.accountID != nil { throw TerminalError.invalid("The original account authorization is unavailable") }
        let selectedOrganization = try operations.selectedOrganizationUUID(run.source, authorization)
        let authentication = try seed(run.source)
        guard authentication.sourceFingerprint == authenticationWitness else { throw TerminalError.invalid("The original authentication changed during twin preparation") }
        try requireAuthentication(run.source, authentication)
        if let selectedOrganization, let identity = authentication.credentialFiles[".claude.json"],
           let metadata = try JSONSerialization.jsonObject(with: identity) as? [String: Any],
           let account = metadata["oauthAccount"] as? [String: Any], let organization = account["organizationUuid"] as? String,
           organization.lowercased() != selectedOrganization.lowercased() { throw TerminalError.invalid("The copied Claude account belongs to another selected organization") }
        if let authorization { try operations.revalidateOrganization(authorization, run.source, snapshot.worktreePath) }
        try requireSame(run, frozen)
        let directory = URL(fileURLWithPath: snapshot.worktreePath).deletingLastPathComponent()
        try TwinLaunchPreparationFiles.validateDirectory(directory.path, privateLeaf: true)
        let profile = directory.appendingPathComponent("profile").path
        let plan = try TwinProviderPlanner.plan(TwinProviderRequest(provider: run.source.provider, mode: run.mode,
            sourceConversationID: run.source.conversationID, worktree: snapshot.worktreePath,
            configurationRoot: run.source.configurationRoot, privateProfileRoot: profile,
            providerExecutable: executable, helperExecutable: operations.helperExecutable,
            apiSocketPath: try operations.scopedSocket(run.id), runID: run.id, round: round.number, selectedOrganizationUUID: selectedOrganization))
        try requireAuthentication(run.source, authentication)
        let accessOnly = try TwinAccessOnlyCredentials.prepare(provider: run.source.provider, seed: authentication)
        try TwinProviderProfile.prepare(plan: plan, credentialFiles: accessOnly.files, conversation: conversation)
        var expectedFiles = plan.files.merging(accessOnly.files) { _, new in new }
        if let conversation { expectedFiles[conversation.relativePath] = conversation.data }
        let authenticationProof = try TwinAuthenticationSeedProof(seed: authentication, files: expectedFiles, selectedOrganizationUUID: selectedOrganization, expiresAt: accessOnly.expiresAt)
        try authenticationProof.verify(seed: seed(run.source), profileRoot: profile)
        try requireSame(run, frozen)
        if let authorization { try operations.revalidateOrganization(authorization, run.source, snapshot.worktreePath) }
        let ticket = TwinLaunchTicket(runID: run.id, round: round.number, source: run.source, sourceCompletion: completion,
            configurationRoot: profile, providerExecutable: plan.executable, args: plan.arguments,
            environment: plan.environment, removeEnvironment: plan.removeEnvironment,
            sourceOrganizationAuthorization: authorization, authenticationSeedProof: authenticationProof,
            sourceTranscriptSHA256: conversation.map { Self.digest($0.data) }, sourceTranscriptRelativePath: conversation?.relativePath)
        try requireAuthentication(run.source, authentication)
        try authenticationProof.verify(seed: seed(run.source), profileRoot: profile)
        _ = try TwinLaunchTicketStore(root: root, runID: run.id, round: round.number).create(ticket)
        try requireSame(run, frozen)
        return snapshot
    }
    private func seed(_ source: TwinSourceBinding) throws -> TwinAuthenticationSeed {
        if let capture = operations.authenticationSeed { return try capture(source) }
        return try .freezing(operations.credentials(source))
    }
    private func requireAuthentication(_ source: TwinSourceBinding, _ expected: TwinAuthenticationSeed) throws {
        guard try seed(source) == expected else { throw TerminalError.invalid("The original credentials changed while the twin was being frozen") }
    }
    private func current(_ run: TwinRun) throws -> TwinRuntimeContext {
        guard operations.active() else { throw TerminalError.invalid("Twin preparation was stopped") }
        return try operations.context(run)
    }
    private func requireSame(_ run: TwinRun, _ frozen: TwinRuntimeContext) throws {
        guard try current(run) == frozen else { throw TerminalError.invalid("The original task or input changed during twin preparation") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum TwinLaunchPreparationFiles {
    static func validateDirectory(_ path: String, privateLeaf: Bool) throws {
        let fd = try openDirectory(path, privateLeaf: privateLeaf)
        close(fd)
    }
    private static func openDirectory(_ path: String, privateLeaf: Bool) throws -> Int32 {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TerminalError.invalid("Invalid twin launch directory")
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot inspect twin launch directory") }
        do {
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw TerminalError.invalid("Twin launch directories cannot contain links") }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), !privateLeaf || info.st_mode & 0o077 == 0 else {
                throw TerminalError.invalid("Twin launch directory must be owned and private")
            }
            return fd
        } catch { close(fd); throw error }
    }
}

private enum TwinLaunchFileError: Error { case missing }

extension TwinLaunchPreparationFiles {
    public static func readOwned(root: String, relativePath: String, limit: Int, privateFile: Bool = true) throws -> Data {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.hasPrefix("/"), !parts.isEmpty, limit > 0, limit <= 134_217_728,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.utf8.contains(0) }) else {
            throw TerminalError.invalid("Invalid source profile file")
        }
        var parent = try openDirectory(root, privateLeaf: false)
        defer { close(parent) }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { throw TwinLaunchFileError.missing }
                throw TerminalError.invalid("Source profile directories cannot contain links")
            }
            close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw TwinLaunchFileError.missing }
            throw TerminalError.invalid("The source profile file cannot be safely opened")
        }
        defer { close(fd) }
        var before = stat(), after = stat(), pathInfo = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_nlink == 1, before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= limit,
              !privateFile || before.st_mode & 0o077 == 0 else { throw TerminalError.invalid("Source profile file ownership, permissions or size is invalid") }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + max(0, count) <= limit else { throw TerminalError.invalid("The source profile file exceeded its read bound") }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard fstat(fd, &after) == 0, fstatat(parent, parts.last!, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(after, pathInfo), data.count == before.st_size else {
            throw TerminalError.invalid("The source profile file changed while it was being frozen")
        }
        return data
    }
    static func optional(root: String, relativePath: String, limit: Int, privateFile: Bool = true) throws -> Data? {
        do { return try readOwned(root: root, relativePath: relativePath, limit: limit, privateFile: privateFile) }
        catch TwinLaunchFileError.missing { return nil }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    public static func validateConversation(_ seed: TwinConversationSeed, source: TwinSourceBinding) throws {
        let filename = URL(fileURLWithPath: seed.relativePath).lastPathComponent
        guard !seed.data.isEmpty, seed.data.count <= 134_217_728, seed.data.last == 10,
              !seed.relativePath.hasPrefix("/"), !seed.relativePath.split(separator: "/").contains(".."),
              source.provider != .shell, UUID(uuidString: source.conversationID) != nil,
              (source.provider == .claude ? filename.lowercased() == source.conversationID.lowercased() + ".jsonl" : filename.lowercased().hasSuffix("-" + source.conversationID.lowercased() + ".jsonl")) else {
            throw TerminalError.invalid("The complete exact source conversation is unavailable")
        }
        var metadata = false
        for (index, line) in seed.data.split(separator: 10).enumerated() {
            guard line.count <= 8_388_608,
                  let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw TerminalError.invalid("The source conversation contains an invalid or partial record")
            }
            if source.provider == .claude {
                guard row["isSidechain"] as? Bool != true, row["agentId"] == nil, row["agent_id"] == nil,
                      row["entrypoint"] == nil || row["entrypoint"] as? String == "cli" else {
                    throw TerminalError.invalid("The source conversation contains another agent")
                }
                if let id = row["sessionId"] as? String {
                    guard id.lowercased() == source.conversationID.lowercased(), row["isSidechain"] as? Bool != true,
                          row["agentId"] == nil, row["agent_id"] == nil,
                          row["entrypoint"] == nil || row["entrypoint"] as? String == "cli" else {
                        throw TerminalError.invalid("The source conversation contains another agent or session")
                    }
                    if row["cwd"] as? String == source.cwd { metadata = true }
                }
            } else {
                if index == 0 || row["type"] as? String == "session_meta" {
                    guard row["type"] as? String == "session_meta", let payload = row["payload"] as? [String: Any],
                          (payload["id"] as? String)?.lowercased() == source.conversationID.lowercased(), payload["cwd"] as? String == source.cwd,
                          payload["source"] as? String == "cli" else {
                        throw TerminalError.invalid("The source conversation has different provider metadata")
                    }
                    metadata = true
                }
            }
        }
        guard metadata else { throw TerminalError.invalid("The exact source conversation metadata is missing") }
    }
}

public struct TwinLaunchCredentialReader {
    public var keychain: (String) throws -> Data?
    public var environmentCheck: (TwinSourceBinding) throws -> Void
    public init(keychain: @escaping (String) throws -> Data? = TwinLaunchCredentialReader.nativeClaudeKeychain,
                environmentCheck: @escaping (TwinSourceBinding) throws -> Void = { try TwinSourceEnvironment.validate(source: $0) }) {
        self.keychain = keychain; self.environmentCheck = environmentCheck
    }
    public func credentials(source: TwinSourceBinding) throws -> [String: Data] { try capture(source: source).credentialFiles }
    public func capture(source: TwinSourceBinding) throws -> TwinAuthenticationSeed {
        try environmentCheck(source)
        let name = source.provider == .claude ? ".credentials.json" : "auth.json"
        guard [.claude, .codex].contains(source.provider) else { throw TerminalError.invalid("A shell has no forkable provider credentials") }
        let file = try TwinLaunchPreparationFiles.optional(root: source.configurationRoot, relativePath: name, limit: 1_048_576)
        let fileObject = try file.map(Self.canonicalCredential)
        let keychainValue = source.provider == .claude ? try keychain(source.configurationRoot) : nil
        let keychainObject = try keychainValue.map(Self.canonicalCredential)
        if let fileObject, let keychainObject, fileObject != keychainObject { throw TerminalError.invalid("The original file and Keychain credentials differ; the effective account is ambiguous") }
        guard let credential = file ?? keychainValue else { throw TerminalError.invalid("The original account credentials are unavailable; no alternate account was selected") }
        var files = [name: credential]
        if source.provider == .claude, let identity = try oauthIdentity(root: source.configurationRoot) { files[".claude.json"] = identity }
        let fingerprint = try TwinAuthenticationSeed.fingerprint(["provider": source.provider.rawValue, "root": source.configurationRoot, "account": source.accountID ?? "unregistered",
            "file": file.map(TwinAuthenticationSeed.digest) ?? "missing", "keychain": keychainValue.map(TwinAuthenticationSeed.digest) ?? "missing",
            "identity": files[".claude.json"].map(TwinAuthenticationSeed.digest) ?? "missing"])
        try environmentCheck(source)
        return TwinAuthenticationSeed(credentialFiles: files, sourceFingerprint: fingerprint)
    }
    public func selectedOrganization(source: TwinSourceBinding) throws -> String? {
        guard source.provider == .claude, let data = try capture(source: source).credentialFiles[".claude.json"],
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any], let value = account["organizationUuid"] as? String else { return nil }
        guard let identifier = UUID(uuidString: value) else { throw TerminalError.invalid("The original Claude organization identity is invalid") }
        return identifier.uuidString.lowercased()
    }
    private static func canonicalCredential(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 1_048_576, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw TerminalError.invalid("The original authentication is invalid")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func oauthIdentity(root: String) throws -> Data? {
        let own = try TwinLaunchPreparationFiles.optional(root: root, relativePath: ".claude.json", limit: 1_048_576)
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        var sibling: Data?
        if root == defaultRoot {
            let location = URL(fileURLWithPath: root + ".json")
            sibling = try TwinLaunchPreparationFiles.optional(root: location.deletingLastPathComponent().path, relativePath: location.lastPathComponent, limit: 1_048_576)
        }
        var result: [String: Any]?
        for data in [own, sibling].compactMap({ $0 }) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TerminalError.invalid("Original Claude account metadata is invalid") }
            guard let raw = object["oauthAccount"] as? [String: Any] else { continue }
            let keys: Set<String> = ["accountUuid", "emailAddress", "organizationUuid", "displayName", "billingType", "hasExtraUsageEnabled"]
            let identity = raw.filter { keys.contains($0.key) }
            guard !identity.isEmpty, identity.values.allSatisfy({ value in
                value is Bool || (value as? String).map { $0.utf8.count <= 4096 && !$0.utf8.contains(0) } == true
            }) else { throw TerminalError.invalid("Original Claude account identity is invalid") }
            if let previous = result {
                guard NSDictionary(dictionary: previous).isEqual(to: identity) else { throw TerminalError.invalid("Original Claude account identity is ambiguous") }
            }
            result = identity
        }
        guard let result else { return nil }
        var data = try JSONSerialization.data(withJSONObject: ["oauthAccount": result], options: [.sortedKeys]); data.append(10)
        return data
    }
    public static func nativeClaudeKeychain(_ root: String) throws -> Data? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let suffix = String(TwinLaunchPreparer.digest(Data(root.precomposedStringWithCanonicalMapping.utf8)).prefix(8))
        let hashed = ["Claude Code-credentials-" + suffix, "Claude Code-" + suffix]
        let services = root == home ? ["Claude Code-credentials", "Claude Code"] + hashed : hashed
        let account = NSUserName()
        guard !account.isEmpty else { throw TerminalError.invalid("The original Claude keychain account is unavailable") }
        var candidates: [Data] = []
        for service in services {
            let context = LAContext(); context.interactionNotAllowed = true
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data, !data.isEmpty, data.count <= 1_048_576 else {
                throw TerminalError.invalid("The original Claude keychain credential is unavailable without interaction")
            }
            _ = try canonicalCredential(data)
            candidates.append(data)
        }
        guard let selected = candidates.first else { return nil }
        let canonical = try canonicalCredential(selected)
        guard try candidates.allSatisfy({ try canonicalCredential($0) == canonical }) else { throw TerminalError.invalid("The original Keychain credential candidates are ambiguous") }
        return selected
    }
}

public enum TwinLaunchNativePreparation {
    public static func executable(source: TwinSourceBinding) throws -> String {
        guard SupervisorProcessIdentity.read(source.providerPID) == source.providerIdentity else { throw TerminalError.invalid("The original provider process changed") }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(source.providerPID, &buffer, UInt32(buffer.count)) > 0,
              SupervisorProcessIdentity.read(source.providerPID) == source.providerIdentity else {
            throw TerminalError.invalid("The exact original provider executable is unavailable")
        }
        let path = String(cString: buffer)
        guard TwinProviderPlanner.validPath(path), FileManager.default.isExecutableFile(atPath: path),
              path == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path else {
            throw TerminalError.invalid("The original provider executable is not a canonical local binary")
        }
        let result = try CommandRunner.run(path, ["--version"], environment: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "DISABLE_AUTOUPDATER": "1"], timeout: 5, limit: 4096)
        let version = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else { throw TerminalError.invalid("The exact provider version is unavailable") }
        try TwinProviderPlanner.validateVersion(provider: source.provider, output: version)
        return path
    }
    public static func conversation(source: TwinSourceBinding, mode: TwinReviewMode) throws -> TwinConversationSeed? {
        if mode == .securityReview { return nil }
        let descriptor = ConversationHistorySource(id: "twin-source", provider: source.provider, configurationRoot: source.configurationRoot, accountID: source.accountID, label: "Original")
        let history = ConversationHistoryIndex.discover(sources: [descriptor], limits: .init(maxSources: 1, maxVisitedEntries: 50_000, maxFiles: 1024, maxTotalBytes: 67_108_864, maxConversations: 1000))
        let exact = history.conversations.filter { $0.providerSessionID.lowercased() == source.conversationID.lowercased() && $0.cwd == source.cwd && $0.source == descriptor }
        guard exact.count == 1 else { throw TerminalError.invalid("The exact source conversation is missing or ambiguous") }
        let verified = try ConversationHistoryIndex.validate(conversation: exact[0])
        let data = try TwinLaunchPreparationFiles.readOwned(root: source.configurationRoot, relativePath: verified.relativePath, limit: 134_217_728, privateFile: false)
        let seed = TwinConversationSeed(relativePath: verified.relativePath, data: data)
        try TwinLaunchPreparationFiles.validateConversation(seed, source: source)
        return seed
    }
}

extension TerminalRuntime {
    public func twinLaunchTicket(runID: String, round: Int) throws -> TwinLaunchTicket {
        try TwinLaunchTicketStore(root: root, runID: runID, round: round).load()
    }
    @discardableResult public func updateTwinLaunchTicket(runID: String, round: Int, mutation: (inout TwinLaunchTicket) throws -> Void) throws -> TwinLaunchTicket {
        try TwinLaunchTicketStore(root: root, runID: runID, round: round).update(mutation)
    }
    public func prepareTwinSnapshot(run: TwinRun, round: TwinRound, active: @escaping () -> Bool) throws -> TwinGitSnapshot {
        try assertOutsideSharedTransaction()
        guard let helperExecutable else { throw TerminalError.invalid("A pessimistic twin requires the bundled native helper") }
        let operations = TwinLaunchPreparationOperations(context: { try self.twinSourceContext(run: $0, active: active()) },
            snapshot: { try TwinGitService(root: self.root).snapshot(source: $0.source, runID: $0.id, round: $1.number) },
            executable: { try TwinLaunchNativePreparation.executable(source: $0) },
            credentials: { source in
                try self.validateTwinSourceAccount(source)
                return try TwinLaunchCredentialReader().credentials(source: source)
            }, conversation: { try TwinLaunchNativePreparation.conversation(source: $0, mode: $1) },
            organization: { source, cwd in
                try self.validateTwinSourceAccount(source)
                guard let accountID = source.accountID else { return nil }
                return try self.preflightAccountOrganization(accountID: accountID, cwd: cwd, command: nil)
            }, revalidateOrganization: { proof, source, cwd in
                try self.validateTwinSourceAccount(source)
                try self.revalidateAccountOrganizationAuthorization(proof, cwd: cwd)
            }, scopedSocket: { try self.twinSocketPath(runID: $0) }, helperExecutable: helperExecutable, active: active,
            authenticationSeed: { source in try self.validateTwinSourceAccount(source); return try TwinLaunchCredentialReader().capture(source: source) },
            selectedOrganizationUUID: { source, proof in try self.twinSelectedOrganization(source: source, proof: proof) })
        return try TwinLaunchPreparer(root: root, operations: operations).prepare(run: run, round: round)
    }
    public func validateTwinFrozenAuthentication(ticket: TwinLaunchTicket) throws {
        try assertOutsideSharedTransaction()
        guard let proof = ticket.authenticationSeedProof else { throw TerminalError.invalid("This twin was prepared without a frozen authentication proof") }
        guard try TwinLaunchNativePreparation.executable(source: ticket.source) == ticket.providerExecutable else { throw TerminalError.invalid("The pinned provider executable changed before launch") }
        let saved = try twinLaunchTicket(runID: ticket.runID, round: ticket.round)
        guard saved.hasSameLaunch(as: ticket) else { throw TerminalError.invalid("The frozen twin launch identity changed") }
        let run = try requireTwin(ticket.runID)
        guard run.source == ticket.source, run.currentRound == ticket.round,
              let worktree = run.latestRound?.snapshot?.worktreePath else { throw TerminalError.invalid("The owned twin worktree changed before launch") }
        try TwinFileAliasAdmission.validate(worktree: worktree, temporaryDirectory: ticket.configurationRoot + "/tmp")
        try validateTwinSourceAccount(ticket.source)
        let selected = try twinSelectedOrganization(source: ticket.source, proof: ticket.sourceOrganizationAuthorization)
        guard selected?.lowercased() == proof.selectedOrganizationUUID?.lowercased() else { throw TerminalError.invalid("The selected source organization changed") }
        if let authorization = ticket.sourceOrganizationAuthorization { try revalidateAccountOrganizationAuthorization(authorization, cwd: FileManager.default.currentDirectoryPath) }
        try proof.verify(seed: TwinLaunchCredentialReader().capture(source: ticket.source), profileRoot: ticket.configurationRoot)
    }
    private func twinSelectedOrganization(source: TwinSourceBinding, proof: AccountOrganizationAuthorization?) throws -> String? {
        guard source.provider == .claude else { return nil }
        let observed = try TwinLaunchCredentialReader().selectedOrganization(source: source)
        guard let accountID = source.accountID else { return observed }
        try validateTwinSourceAccount(source)
        guard let account = try state().accounts.first(where: { $0.id == accountID }),
              proof?.accountID == accountID, proof?.configurationRoot == source.configurationRoot,
              proof?.bindingID == (account.organizationUsageBindingID ?? "") else { throw TerminalError.invalid("The source organization proof changed") }
        let selected = account.organization?.selection?.uuid
        if let selected, let observed, selected.lowercased() != observed.lowercased() { throw TerminalError.invalid("The original Claude organization does not match the selected profile") }
        return selected ?? observed
    }
    private func validateTwinSourceAccount(_ source: TwinSourceBinding) throws {
        guard let accountID = source.accountID else { return }
        let current = try state()
        guard let account = current.accounts.first(where: { $0.id == accountID && $0.provider == source.provider && $0.enabled }),
              try accountRoot(accountID).path == source.configurationRoot,
              let launch = current.agentLaunches.first(where: { $0.paneID == source.paneID && $0.id == source.generation && $0.lifecycle == .active }),
              launch.accountID == accountID, launch.provider == source.provider, launch.configurationRoot == source.configurationRoot,
              launch.organizationBindingID == account.organizationUsageBindingID else {
            throw TerminalError.invalid("The original account or organization changed before the twin could be prepared")
        }
    }
}
