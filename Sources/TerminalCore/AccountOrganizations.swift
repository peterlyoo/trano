import Foundation
import Darwin

public struct ClaudeOrganizationSelection: Codable, Equatable, Identifiable, Sendable {
    public let uuid: String
    public let name: String?
    public var id: String { uuid }
    public init(uuid: String, name: String?) throws {
        guard uuid.utf8.count == 36, let identifier = UUID(uuidString: uuid) else {
            throw TerminalError.invalid("Enter an organization UUID")
        }
        if let name {
            guard name.count <= 120, name.utf8.count <= 512,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw TerminalError.invalid("Use an organization name of at most 120 characters without controls")
            }
        }
        self.uuid = identifier.uuidString.lowercased()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
    }
    private enum CodingKeys: String, CodingKey { case uuid, name }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(uuid: values.decode(String.self, forKey: .uuid), name: values.decodeIfPresent(String.self, forKey: .name))
    }
}
public enum AccountOrganizationVerification: String, Codable, Sendable { case unbound, unverified, verified, mismatch, missing, unavailable }
public struct AccountOrganizationState: Codable, Equatable, Sendable {
    public var selection: ClaudeOrganizationSelection?
    public var observed: ClaudeOrganizationSelection?
    public var verification: AccountOrganizationVerification
    public var checkedAt: Date?
    public var bindingID: String
    public var profileEnabled: Bool?
    public var profilePinned: Bool?
    public var authenticationFingerprint: AccountAuthenticationFingerprint? = nil
    public var quotaUnavailableUntil: Date? = nil
    public init(selection: ClaudeOrganizationSelection? = nil, observed: ClaudeOrganizationSelection? = nil, verification: AccountOrganizationVerification = .unverified, checkedAt: Date? = nil, bindingID: String = "", profileEnabled: Bool? = nil, profilePinned: Bool? = nil, authenticationFingerprint: AccountAuthenticationFingerprint? = nil, quotaUnavailableUntil: Date? = nil) {
        self.selection = selection; self.observed = observed; self.verification = verification; self.checkedAt = checkedAt; self.bindingID = bindingID
        self.profileEnabled = profileEnabled; self.profilePinned = profilePinned
        self.authenticationFingerprint = authenticationFingerprint
        self.quotaUnavailableUntil = quotaUnavailableUntil
    }
    func validate() throws {
        guard (bindingID.isEmpty && selection == nil) || (bindingID.utf8.count == 36 && UUID(uuidString: bindingID) != nil),
              checkedAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 }) ?? true else {
            throw TerminalError.invalid("Invalid organization verification state")
        }
        if let quotaUnavailableUntil, !quotaUnavailableUntil.timeIntervalSince1970.isFinite { throw TerminalError.invalid("Invalid organization quota cooldown") }
        if let authenticationFingerprint, !authenticationFingerprint.isValid { throw TerminalError.invalid("Invalid authentication identity fingerprint") }
        if verification == .verified {
            guard selection != nil, observed?.uuid == selection?.uuid, checkedAt != nil else {
                throw TerminalError.invalid("Organization verification has no matching observation")
            }
        }
    }
}

public struct AccountOrganizationAuthorization: Codable, Equatable, Sendable {
    public let accountID: String
    public let bindingID: String
    public var configurationRoot: String
    public var authenticationContext: ClaudeAuthenticationContext? = nil
    public let checkedAt: Date
    public var authenticationFingerprint: AccountAuthenticationFingerprint? = nil
}

private struct AccountOrganizationSidecar: Codable {
    var schemaVersion = 1
    var profiles: [String: AccountOrganizationState] = [:]
    func validate() throws {
        guard schemaVersion == 1, profiles.count <= 1000 else { throw TerminalError.invalid("Unsupported organization profile metadata") }
        for (id, value) in profiles {
            guard id.utf8.count == 36, UUID(uuidString: id) != nil else { throw TerminalError.invalid("Invalid organization account identity") }
            try value.validate()
        }
    }
}

enum AccountOrganizationSettings {
    static func applying(_ selection: ClaudeOrganizationSelection?, previous: ClaudeOrganizationSelection?, to data: Data) throws -> Data {
        var settings = try AccountUsageAdapter.object(data)
        if let selection {
            settings["forceLoginOrgUUID"] = selection.uuid
            settings["forceLoginMethod"] = "claudeai"
        } else if let previous {
            if settings["forceLoginOrgUUID"] as? String == previous.uuid { settings.removeValue(forKey: "forceLoginOrgUUID") }
            if settings["forceLoginMethod"] as? String == "claudeai" { settings.removeValue(forKey: "forceLoginMethod") }
        }
        return try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted]) + Data([10])
    }
}

enum AccountOrganizationWritePhase { case legacyBarrier, marker, settings, metadata, restoreLegacy, publishPrimary }

private extension AccountAuthenticationFingerprint {
    var accountIdentity: Self {
        Self(ownedFilesDigest: ownedFilesDigest, keychainDigest: keychainDigest, executableDigest: executableDigest)
    }
}

extension TerminalRuntime {
    private var organizationSidecarURL: URL { root.appendingPathComponent("account-organizations-v1.json") }

    func organizationSidecarData() throws -> Data? {
        let fd = open(organizationSidecarURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private organization metadata") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 2 * 1_048_576 else {
            throw TerminalError.invalid("Organization metadata must be a private owned regular file of at most 2 MiB")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= 2 * 1_048_576 else { throw TerminalError.invalid("Cannot read bounded organization metadata") }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func organizationSidecar() throws -> AccountOrganizationSidecar {
        try organizationSidecar(organizationSidecarData())
    }

    private func organizationSidecar(_ data: Data?) throws -> AccountOrganizationSidecar {
        guard let data else { return AccountOrganizationSidecar() }
        let result = try JSONDecoder().decode(AccountOrganizationSidecar.self, from: data)
        try result.validate()
        return result
    }

    private func writeOrganizationSidecar(_ value: AccountOrganizationSidecar) throws {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 2 * 1_048_576 else { throw TerminalError.invalid("Organization metadata exceeds 2 MiB") }
        try Self.atomicWrite(data, to: organizationSidecarURL)
    }

    func restoreAccountOrganizations(to state: inout RuntimeState, data: Data?) throws {
        let metadata = try organizationSidecar(data)
        for index in state.accounts.indices {
            var value = state.accounts[index].provider == .claude ? metadata.profiles[state.accounts[index].id] : nil
            if value?.verification == .verified, value?.authenticationFingerprint == nil { value?.verification = .unverified }
            state.accounts[index].organization = value
            if state.accounts[index].organizationUsageBindingID != nil {
                state.accounts[index].unavailableUntil = value?.quotaUnavailableUntil
            }
            if let value {
                if let enabled = value.profileEnabled { state.accounts[index].enabled = enabled }
                else if value.selection != nil { state.accounts[index].enabled = false }
                if let pinned = value.profilePinned { state.accounts[index].pinned = pinned }
                else if value.selection != nil { state.accounts[index].pinned = true }
            }
        }
    }

    func setOrganizationAccountCooldown(_ id: String, until: Date?) throws {
        var sidecar = try organizationSidecar()
        guard var value = sidecar.profiles[id], !value.bindingID.isEmpty else { throw TerminalError.invalid("Organization quota scope is unavailable") }
        value.quotaUnavailableUntil = until
        sidecar.profiles[id] = value
        try writeOrganizationSidecar(sidecar)
        try update { _ in }
    }

    func persistAccountOrganizations(from state: inout RuntimeState) throws {
        var sidecar = try organizationSidecar()
        var changed = false
        for index in state.accounts.indices {
            let id = state.accounts[index].id
            if var value = sidecar.profiles[id], state.accounts[index].provider == .claude {
                if value.selection != nil {
                    if value.profileEnabled != state.accounts[index].enabled || value.profilePinned != state.accounts[index].pinned {
                        value.profileEnabled = state.accounts[index].enabled
                        value.profilePinned = state.accounts[index].pinned
                        sidecar.profiles[id] = value
                        changed = true
                    }
                    state.accounts[index].enabled = false
                    state.accounts[index].pinned = true
                } else if value.profileEnabled != nil || value.profilePinned != nil {
                    value.profileEnabled = nil; value.profilePinned = nil
                    sidecar.profiles[id] = value
                    changed = true
                }
            }
            state.accounts[index].organization = nil
        }
        if changed { try writeOrganizationSidecar(sidecar) }
    }

    private func publishLegacyAccountOrganizationBarrier(_ id: String) throws {
        let target = root.appendingPathComponent("state.json")
        let data = try AccountFile.read(target, limit: 64 * 1_048_576)
        guard var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var accounts = raw["accounts"] as? [[String: Any]],
              let index = accounts.firstIndex(where: { $0["id"] as? String == id }) else {
            throw TerminalError.invalid("Account registry changed before organization save")
        }
        accounts[index]["enabled"] = false
        accounts[index]["pinned"] = true
        accounts[index].removeValue(forKey: "organization")
        raw["accounts"] = accounts
        raw["revision"] = ((raw["revision"] as? Int) ?? 0) + 1
        try Self.atomicWrite(JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), to: target)
    }

    public func setAccountOrganization(_ id: String, selection: ClaudeOrganizationSelection?, expectedBindingID: String? = nil) throws {
        try setAccountOrganization(id, selection: selection, expectedBindingID: expectedBindingID, beforeWrite: { _ in })
    }

    func setAccountOrganization(_ id: String, selection: ClaudeOrganizationSelection?, expectedBindingID: String?,
                                beforeWrite: (AccountOrganizationWritePhase) throws -> Void) throws {
        try transaction {
            guard let profile = try state().accounts.first(where: { $0.id == id }), profile.provider == .claude else {
                throw TerminalError.invalid("Organization selection is available for managed Claude profiles")
            }
            let previous = profile.organization
            if let expectedBindingID, expectedBindingID != (previous?.bindingID ?? "") {
                throw TerminalError.invalid("This organization's configuration changed. Reopen its editor.")
            }
            guard previous?.selection != selection else { return }
            let directory = try accountRoot(id)
            let settings = directory.appendingPathComponent("settings.json")
            let marker = directory.appendingPathComponent(".trano-account")
            let primary = root.appendingPathComponent("state.json")
            let oldSettings = try AccountFile.read(settings, limit: 1_048_576)
            let oldMarker = try AccountFile.read(marker, limit: 64)
            let oldPrimary = try AccountFile.read(primary, limit: 64 * 1_048_576)
            let newSettings = try AccountOrganizationSettings.applying(selection, previous: previous?.selection, to: oldSettings)
            let oldSidecar = try organizationSidecarData()
            var sidecar = try organizationSidecar()
            sidecar.profiles[id] = AccountOrganizationState(selection: selection, verification: selection == nil ? .unbound : .unverified,
                bindingID: UUID().uuidString.lowercased(), profileEnabled: profile.enabled, profilePinned: profile.pinned)
            do {
                if selection != nil {
                    try beforeWrite(.legacyBarrier)
                    try publishLegacyAccountOrganizationBarrier(id)
                    try beforeWrite(.marker)
                    try Self.atomicWrite(Data("trano-account-org-v1\n".utf8), to: marker)
                }
                try beforeWrite(.settings)
                try Self.atomicWrite(newSettings, to: settings)
                try beforeWrite(.metadata)
                try writeOrganizationSidecar(sidecar)
                if selection == nil {
                    try beforeWrite(.restoreLegacy)
                    try Self.atomicWrite(Data("trano-account-v1\n".utf8), to: marker)
                }
                try beforeWrite(.publishPrimary)
                try update { _ in }
            } catch {
                let failure = error
                do {
                    try Self.atomicWrite(Data("trano-account-org-v1\n".utf8), to: marker)
                    try Self.atomicWrite(oldSettings, to: settings)
                    if let oldSidecar { try Self.atomicWrite(oldSidecar, to: organizationSidecarURL) }
                    else if FileManager.default.fileExists(atPath: organizationSidecarURL.path) { try FileManager.default.removeItem(at: organizationSidecarURL) }
                    try Self.atomicWrite(oldPrimary, to: primary)
                    try Self.atomicWrite(oldMarker, to: marker)
                } catch { throw TerminalError.runtime("Organization save and rollback failed; this profile remains blocked for older helpers") }
                throw failure
            }
        }
    }

    func prepareAccountOrganizationLogin(_ id: String) throws {
        try transaction {
            guard let selection = try state().accounts.first(where: { $0.id == id })?.organization?.selection else { return }
            let settings = try accountRoot(id).appendingPathComponent("settings.json")
            let original = try AccountFile.read(settings, limit: 1_048_576)
            let merged = try AccountOrganizationSettings.applying(selection, previous: selection, to: original)
            if merged != original { try Self.atomicWrite(merged, to: settings) }
        }
    }

    public func knownAccountOrganizations() throws -> [ClaudeOrganizationSelection] {
        var choices: [ClaudeOrganizationSelection] = []
        for profile in try state().accounts where profile.provider == .claude {
            for value in [profile.organization?.selection, profile.organization?.observed].compactMap({ $0 }) {
                if !choices.contains(where: { $0.uuid == value.uuid }) { choices.append(value) }
            }
        }
        return choices
    }

    public func refreshAccountOrganization(accountID: String, expectedBindingID: String? = nil, context: ClaudeAuthenticationContext? = nil) throws -> AccountOrganizationState? {
        try refreshAccountOrganization(accountID: accountID, expectedBindingID: expectedBindingID, context: context,
                                       authenticate: { account, _ in try self.accountAuthentication(accountID: account.id) })
    }

    func refreshAccountOrganization(accountID: String, expectedBindingID: String? = nil, context: ClaudeAuthenticationContext? = nil,
                                    authenticate: (AccountProfile, URL) throws -> AccountAuthenticationSnapshot) throws -> AccountOrganizationState? {
        try assertOutsideSharedTransaction()
        guard let profile = try state().accounts.first(where: { $0.id == accountID }), profile.provider == .claude else {
            throw TerminalError.invalid("Choose a managed Claude profile")
        }
        let bindingID = profile.organization?.bindingID ?? ""
        if let expectedBindingID, expectedBindingID != bindingID { throw TerminalError.invalid("Organization selection changed. Refresh its editor.") }
        let directory = try accountRoot(accountID)
        if profile.organization?.selection != nil { try prepareAccountOrganizationLogin(accountID) }
        let unavailable = AccountAuthenticationSnapshot(accountID: accountID, provider: .claude, status: .unknown, checkedAt: Date(),
                                                          organizationVerification: profile.organization?.selection == nil ? .unbound : .unavailable)
        var snapshot = unavailable
        var fingerprint: AccountAuthenticationFingerprint?
        do {
            let before = profile.organization?.selection == nil ? nil : try accountAuthenticationIdentityReader.capture(accountID: accountID, root: directory, runtimeRoot: root, context: context)
            snapshot = try authenticate(profile, directory)
            if let before {
                let after = try accountAuthenticationIdentityReader.capture(accountID: accountID, root: directory, runtimeRoot: root, context: context)
                guard before == after else { throw TerminalError.invalid("Authentication sources changed during verification") }
                fingerprint = after
            }
        } catch {
            snapshot = unavailable
            fingerprint = nil
        }
        return try transaction {
            guard let current = try state().accounts.first(where: { $0.id == accountID && $0.provider == .claude }),
                  current.organization?.bindingID ?? "" == bindingID,
                  current.organization?.selection == profile.organization?.selection,
                  try accountRoot(accountID) == directory,
                  snapshot.accountID == accountID, snapshot.provider == .claude else {
                throw TerminalError.invalid("Organization selection changed during refresh. Try again.")
            }
            if let captured = fingerprint {
                do { try accountAuthenticationIdentityReader.validateLocalSources(captured, accountID: accountID, root: directory, runtimeRoot: root, context: context) }
                catch { snapshot = unavailable; fingerprint = nil }
            }
            var sidecar = try organizationSidecar()
            let value = AccountOrganizationState(selection: profile.organization?.selection, observed: snapshot.organization,
                verification: snapshot.organizationVerification, checkedAt: snapshot.checkedAt, bindingID: bindingID,
                profileEnabled: profile.organization?.selection != nil ? current.enabled : nil,
                profilePinned: profile.organization?.selection != nil ? current.pinned : nil, authenticationFingerprint: fingerprint?.accountIdentity,
                quotaUnavailableUntil: current.organization?.quotaUnavailableUntil)
            sidecar.profiles[accountID] = value
            try writeOrganizationSidecar(sidecar)
            try update { _ in }
            var result = value
            result.authenticationFingerprint = fingerprint
            return result
        }
    }

    public func preflightAccountOrganization(accountID: String, cwd: String = FileManager.default.currentDirectoryPath, command: AccountCommand? = nil) throws -> AccountOrganizationAuthorization {
        try preflightAccountOrganization(accountID: accountID, cwd: cwd, command: command, authenticate: { account, _ in try self.accountAuthentication(accountID: account.id) })
    }
    func preflightAccountOrganization(accountID: String, cwd: String = FileManager.default.currentDirectoryPath, command: AccountCommand? = nil, authenticate: (AccountProfile, URL) throws -> AccountAuthenticationSnapshot) throws -> AccountOrganizationAuthorization {
        guard let account = try state().accounts.first(where: { $0.id == accountID }), account.enabled else { throw TerminalError.invalid("Account is unavailable") }
        let directory = try accountRoot(accountID)
        if account.provider == .claude, account.organization?.selection != nil, let command {
            try validateOrganizationCommandSettings(command, directory: directory)
        }
        var fingerprint: AccountAuthenticationFingerprint?
        let context = account.provider == .claude && account.organization?.selection != nil ? try ClaudeAuthenticationContext(cwd: cwd) : nil
        if account.provider == .claude, account.organization?.selection != nil {
            fingerprint = try refreshAccountOrganization(accountID: accountID, expectedBindingID: account.organization?.bindingID, context: context, authenticate: authenticate)?.authenticationFingerprint
        }
        let proof = AccountOrganizationAuthorization(accountID: accountID, bindingID: account.organization?.bindingID ?? "",
                                                     configurationRoot: directory.path, authenticationContext: context, checkedAt: Date(), authenticationFingerprint: fingerprint)
        try validateAccountOrganizationAuthorization(proof, cwd: cwd)
        return proof
    }

    private func validateOrganizationCommandSettings(_ command: AccountCommand, directory: URL) throws {
        guard command.environment["CLAUDE_CONFIG_DIR"] == directory.path else { throw TerminalError.invalid("Managed account configuration changed") }
        let allowed = Set(["settings.json", "trano-settings.json"].map { directory.appendingPathComponent($0).standardizedFileURL.path })
        var index = 0
        while index < command.arguments.count {
            let argument = command.arguments[index]
            if argument == "--" { return }
            if ["--setting-sources", "--project-config-root", "--managed-settings", "--cwd"].contains(where: { argument == $0 || argument.hasPrefix($0 + "=") }) {
                throw TerminalError.invalid("Organization-bound profiles use their managed settings sources")
            }
            let value: String?
            if argument == "--settings" {
                guard index + 1 < command.arguments.count else { throw TerminalError.invalid("Missing managed settings path") }
                index += 1
                value = command.arguments[index]
            } else if argument.hasPrefix("--settings=") { value = String(argument.dropFirst("--settings=".count)) }
            else { value = nil }
            if let value {
                guard value.hasPrefix("/"), allowed.contains(URL(fileURLWithPath: value).standardizedFileURL.path) else {
                    throw TerminalError.invalid("Organization-bound profiles accept only their owned settings files")
                }
            }
            index += 1
        }
    }

    public func revalidateAccountOrganizationAuthorization(_ proof: AccountOrganizationAuthorization, cwd: String? = nil) throws {
        try assertOutsideSharedTransaction()
        do {
            try validateAccountOrganizationAuthorization(proof, cwd: cwd)
            if let profile = try state().accounts.first(where: { $0.id == proof.accountID }),
               profile.provider == .claude, profile.organization?.selection != nil {
                try assertOutsideSharedTransaction()
                let current = try accountAuthenticationIdentityReader.capture(accountID: proof.accountID, root: accountRoot(proof.accountID), runtimeRoot: root, context: proof.authenticationContext)
                guard current == proof.authenticationFingerprint else { throw TerminalError.invalid("Authentication sources changed. Verify this organization's login again.") }
            }
            try validateAccountOrganizationAuthorization(proof, cwd: cwd)
        } catch {
            let failure = error
            let identity = try? accountAuthenticationIdentityReader.capture(accountID: proof.accountID,
                root: accountRoot(proof.accountID), runtimeRoot: root)
            if identity?.accountIdentity != proof.authenticationFingerprint?.accountIdentity {
                try? invalidateAccountOrganizationVerification(proof)
            }
            throw failure
        }
    }

    private func invalidateAccountOrganizationVerification(_ proof: AccountOrganizationAuthorization) throws {
        try transaction {
            guard let profile = try state().accounts.first(where: { $0.id == proof.accountID }),
                  var value = profile.organization, value.selection != nil, value.bindingID == proof.bindingID,
                  let fingerprint = proof.authenticationFingerprint,
                  value.authenticationFingerprint?.accountIdentity == fingerprint.accountIdentity else { return }
            value.verification = .unverified
            value.authenticationFingerprint = nil
            var sidecar = try organizationSidecar()
            sidecar.profiles[profile.id] = value
            try writeOrganizationSidecar(sidecar)
            try update { _ in }
        }
    }

    public func validateAccountOrganizationAuthorization(_ proof: AccountOrganizationAuthorization, now: Date = Date(), cwd: String? = nil) throws {
        try transaction {
            guard let account = try state().accounts.first(where: { $0.id == proof.accountID }), account.enabled,
                  try accountRoot(account.id).path == proof.configurationRoot,
                  (account.organization?.bindingID ?? "") == proof.bindingID else {
                throw TerminalError.invalid("The account's organization changed. Refresh before continuing.")
            }
            guard account.provider == .claude, let selection = account.organization?.selection else { return }
            guard let context = proof.authenticationContext, proof.authenticationFingerprint?.contextDigest != nil else {
                throw TerminalError.invalid("Verify this organization for the current project before launching")
            }
            if let cwd, try ClaudeAuthenticationContext(cwd: cwd) != context {
                throw TerminalError.invalid("The project's authentication settings changed. Verify this organization again.")
            }
            guard let state = account.organization, state.verification == .verified,
                  let fingerprint = proof.authenticationFingerprint, fingerprint.accountIdentity == state.authenticationFingerprint?.accountIdentity,
                  state.observed?.uuid == selection.uuid, let checked = state.checkedAt,
                  now.timeIntervalSince(checked) >= -5, now.timeIntervalSince(checked) < 60,
                  now.timeIntervalSince(proof.checkedAt) >= -5, now.timeIntervalSince(proof.checkedAt) < 60 else {
                throw TerminalError.invalid("Claude has not verified this profile's selected organization. Refresh or sign in to the selected organization.")
            }
            try accountAuthenticationIdentityReader.validateLocalSources(fingerprint, accountID: account.id, root: accountRoot(account.id), runtimeRoot: root, context: context)
        }
    }
}
