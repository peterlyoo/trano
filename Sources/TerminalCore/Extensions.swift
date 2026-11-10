import Foundation
import CryptoKit

public enum ExtensionKind: String, Codable, CaseIterable { case skill, plugin, hook, mcp }
public struct ManagedExtension: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString.lowercased()
    public let name: String
    public let kind: ExtensionKind
}
public struct ExtensionPlan: Codable {
    public let accountID: String
    public let extensionIDs: [String]
    public let files: [String: String]
    public let links: [String: String]
    public let unsupported: [String]
}
private struct ExtensionReceipt: Codable {
    var extensionIDs: [String]
    var files: [String: String]
    var links: [String: String]
}

extension TerminalRuntime {
    private func extensionRoot(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw TerminalError.invalid("Invalid extension ID") }
        return try ManagedDirectory.ensure(ManagedDirectory.ensure(root, component: "extensions"), component: id)
    }

    public func importExtension(name: String, kind: ExtensionKind, source: URL) throws -> ManagedExtension {
        guard name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw TerminalError.invalid("Use a name with lowercase letters, numbers, hyphens or underscores") }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        var files: [(String, Data, Bool)] = []
        if kind == .skill {
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else { throw TerminalError.invalid("Select a skill directory") }
            var bytes = 0, count = 0
            for case let file as URL in enumerator {
                count += 1
                guard count <= 1000 else { throw TerminalError.invalid("An extension is limited to 1000 entries") }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw TerminalError.invalid("Extension imports cannot contain symlinks") }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true, let size = values.fileSize, size <= 8_388_608 - bytes else { throw TerminalError.invalid("An extension is limited to 8 MiB of regular files") }
                let data = try Data(contentsOf: file)
                bytes += data.count
                guard bytes <= 8_388_608 else { throw TerminalError.invalid("Extension grew during import") }
                let base = source.resolvingSymlinksInPath().pathComponents
                let components = file.resolvingSymlinksInPath().pathComponents
                guard components.starts(with: base) else { throw TerminalError.invalid("Extension path escaped its source") }
                let relative = components.dropFirst(base.count).joined(separator: "/")
                guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { throw TerminalError.invalid("Invalid extension path") }
                files.append((relative, data, manager.isExecutableFile(atPath: file.path)))
            }
            guard files.contains(where: { $0.0 == "SKILL.md" && !$0.1.isEmpty }) else { throw TerminalError.invalid("A skill must contain SKILL.md") }
        } else {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8_388_608 else { throw TerminalError.invalid("Select a JSON specification of at most 8 MiB") }
            let data = try Data(contentsOf: source)
            _ = try JSONDecoder().decode([String: JSONValue].self, from: data)
            files = [("spec.json", data, false)]
        }
        return try transaction {
            let entry = ManagedExtension(name: name, kind: kind)
            let directory = try extensionRoot(entry.id)
            do {
                for (relative, data, executable) in files {
                    let target = directory.appendingPathComponent(relative)
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try Self.atomicWrite(data, to: target)
                    if executable { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
                }
                try update { $0.extensions.append(entry) }
                return entry
            } catch { try? manager.removeItem(at: directory); throw error }
        }
    }

    public func extensionPlan(accountID: String, extensionIDs: [String]) throws -> ExtensionPlan {
        let state = try state()
        guard let account = state.accounts.first(where: { $0.id == accountID }), extensionIDs.count <= 100,
              extensionIDs.allSatisfy({ id in state.extensions.contains { $0.id == id } }) else { throw TerminalError.invalid("Unknown account or extension") }
        var links: [String: String] = [:], servers: [String: JSONValue] = [:]
        var hooks = Self.activityHooks(account.provider)
        var unsupported: [String] = []
        for id in Set(extensionIDs).sorted() {
            let entry = state.extensions.first { $0.id == id }!
            let source = try extensionRoot(id)
            if entry.kind == .skill {
                let name = "skills/" + entry.name
                guard links[name] == nil else { throw TerminalError.invalid("Two selected skills have the same name") }
                links[name] = source.path
                continue
            }
            let spec = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: source.appendingPathComponent("spec.json")))
            if entry.kind == .plugin { unsupported.append(entry.name + ": use the provider's Install command"); continue }
            if entry.kind == .mcp {
                guard case .object(let entries)? = spec["mcpServers"] else { throw TerminalError.invalid("MCP JSON requires mcpServers") }
                for (name, value) in entries {
                    guard servers[name] == nil, case .object(var options) = value else { throw TerminalError.invalid("Duplicate or invalid MCP server") }
                    if account.provider == .codex {
                        options.removeValue(forKey: "type")
                        if let headers = options.removeValue(forKey: "httpHeaders") { options["http_headers"] = headers }
                    }
                    servers[name] = .object(options)
                }
            } else {
                guard case .object(let entries)? = spec["hooks"] else { throw TerminalError.invalid("Hook JSON requires hooks") }
                for (event, value) in entries {
                    guard case .array(let groups) = value else { throw TerminalError.invalid("Hook events must contain matcher arrays") }
                    if account.provider == .codex && !Self.codexEvents.contains(event) { unsupported.append(entry.name + ": unsupported Codex event " + event); continue }
                    if account.provider == .codex, groups.contains(where: Self.hasUnsupportedCodexHook) { unsupported.append(entry.name + ": Codex requires command or MCP tool handlers"); continue }
                    hooks[event] = .array((hooks[event]?.array ?? []) + groups)
                }
            }
        }
        let files: [String: String]
        if account.provider == .claude {
            files = ["trano-settings.json": try Self.prettyJSON(.object(["hooks": .object(hooks), "statusLine": .object(["type": .string("command"), "command": .string("[ -n \"$TRANO_LAUNCH_ID\" ] && \"$TRANO_CLI_PATH\" usage-hook || true")])])), "trano-mcp.json": try Self.prettyJSON(.object(["mcpServers": .object(servers)]))]
        } else {
            files = ["trano.config.toml": "features = { hooks = true }\nhooks = \(try Self.toml(.object(hooks)))\nmcp_servers = \(try Self.toml(.object(servers)))\n"]
        }
        return ExtensionPlan(accountID: accountID, extensionIDs: Set(extensionIDs).sorted(), files: files, links: links, unsupported: unsupported)
    }

    public func applyExtensions(_ plan: ExtensionPlan) throws {
        try transaction {
            let current = try extensionPlan(accountID: plan.accountID, extensionIDs: plan.extensionIDs)
            guard current.files == plan.files, current.links == plan.links else { throw TerminalError.invalid("Extension content changed; preview again") }
            let directory = try accountRoot(plan.accountID)
            let receiptURL = directory.appendingPathComponent(".trano-extensions.json")
            let manager = FileManager.default
            let receiptData = manager.fileExists(atPath: receiptURL.path) ? try Data(contentsOf: receiptURL) : nil
            let previous = try receiptData.map { try JSONDecoder().decode(ExtensionReceipt.self, from: $0) }
            let allowedFiles: Set<String> = ["trano-settings.json", "trano-mcp.json", "trano.config.toml"]
            guard Set(previous?.files.keys.map { $0 } ?? []).isSubset(of: allowedFiles),
                  (previous?.links.keys.allSatisfy { $0.range(of: "^skills/[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil } ?? true) else { throw TerminalError.invalid("Invalid extension receipt paths") }
            var oldFiles: [String: Data] = [:]
            for path in Set(plan.files.keys).union(previous?.files.keys.map { $0 } ?? []) {
                let url = directory.appendingPathComponent(path)
                if manager.fileExists(atPath: url.path) {
                    let type = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                    guard type == .typeRegular, let expected = previous?.files[path], Self.digest(try Data(contentsOf: url)) == expected else { throw TerminalError.invalid("Refusing to overwrite a modified or unmanaged file: " + path) }
                    oldFiles[path] = try Data(contentsOf: url)
                }
            }
            let skills = try ManagedDirectory.ensure(directory, component: "skills")
            var oldLinks: [String: String] = [:]
            for path in Set(plan.links.keys).union(previous?.links.keys.map { $0 } ?? []) {
                let url = directory.appendingPathComponent(path)
                if let existing = try? manager.destinationOfSymbolicLink(atPath: url.path) {
                    guard existing == previous?.links[path] else { throw TerminalError.invalid("Refusing to replace an unmanaged skill link") }
                    oldLinks[path] = existing
                } else if manager.fileExists(atPath: url.path) { throw TerminalError.invalid("Refusing to replace an existing skill directory") }
            }
            if plan.files.mapValues({ Data($0.utf8) }) == oldFiles, plan.links == oldLinks { return }
            let backup = directory.appendingPathComponent("extension-backup-" + UUID().uuidString)
            try manager.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (path, data) in oldFiles { try Self.atomicWrite(data, to: backup.appendingPathComponent(path)) }
            if let receiptData { try Self.atomicWrite(receiptData, to: backup.appendingPathComponent(".trano-extensions.json")) }
            do {
                for path in oldLinks.keys { try manager.removeItem(at: directory.appendingPathComponent(path)) }
                for (path, target) in plan.links { try manager.createSymbolicLink(at: skills.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent), withDestinationURL: URL(fileURLWithPath: target)) }
                for path in oldFiles.keys where plan.files[path] == nil { try manager.removeItem(at: directory.appendingPathComponent(path)) }
                for (path, content) in plan.files { try Self.atomicWrite(Data(content.utf8), to: directory.appendingPathComponent(path)) }
                let receipt = ExtensionReceipt(extensionIDs: plan.extensionIDs, files: plan.files.mapValues { Self.digest(Data($0.utf8)) }, links: plan.links)
                try Self.atomicWrite(JSONEncoder().encode(receipt), to: receiptURL)
            } catch {
                let failure = error
                do {
                    for path in plan.links.keys where (try? manager.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(path).path)) != nil { try manager.removeItem(at: directory.appendingPathComponent(path)) }
                    for (path, target) in oldLinks {
                        let link = directory.appendingPathComponent(path)
                        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == nil { try manager.createSymbolicLink(atPath: link.path, withDestinationPath: target) }
                    }
                    for path in plan.files.keys where oldFiles[path] == nil {
                        let url = directory.appendingPathComponent(path)
                        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                    }
                    for (path, data) in oldFiles { try Self.atomicWrite(data, to: directory.appendingPathComponent(path)) }
                    if let receiptData { try Self.atomicWrite(receiptData, to: receiptURL) }
                } catch { throw TerminalError.runtime("Extension apply and rollback failed. Backup: " + backup.path) }
                throw failure
            }
        }
    }

    public func enabledExtensions(accountID: String) throws -> [String] {
        let receipt = try accountRoot(accountID).appendingPathComponent(".trano-extensions.json")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return [] }
        return try JSONDecoder().decode(ExtensionReceipt.self, from: Data(contentsOf: receipt)).extensionIDs
    }

    public func pluginCommand(accountID: String, extensionID: String) throws -> AccountCommand {
        let state = try state()
        guard let account = state.accounts.first(where: { $0.id == accountID }),
              state.extensions.contains(where: { $0.id == extensionID && $0.kind == .plugin }) else { throw TerminalError.invalid("Unknown account or plugin") }
        let source = try extensionRoot(extensionID).appendingPathComponent("spec.json")
        let spec = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source))
        guard let selector = spec[account.provider.rawValue], selector.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { throw TerminalError.invalid("This plugin requires a provider-specific name@marketplace selector") }
        var command = try accountCommand(accountID, login: true)
        command.arguments = account.provider == .claude ? ["claude", "plugin", "install", "--scope", "user", selector] : ["codex", "plugin", "add", selector]
        return command
    }

    public func launchPluginInstall(accountID: String, extensionID: String, cwd: String) throws -> LaunchResult {
        _ = try pluginCommand(accountID: accountID, extensionID: extensionID)
        guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else { throw TerminalError.runtime("The bundled trano CLI is required") }
        let result = try launch(cwd: cwd)
        try send(result.pane.id, text: [helperExecutable, "extension", "install", accountID, extensionID].map(ShellQuote.quote).joined(separator: " "), enter: true)
        return result
    }

    static func activityHooks(_ provider: AgentKind) -> [String: JSONValue] {
        let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop"] + (provider == .claude ? ["PostToolUseFailure", "StopFailure"] : ["PreModelRequest", "PostModelRequest"])
        return Dictionary(uniqueKeysWithValues: events.map { event in
            (event, .array([.object(["hooks": .array([.object(["type": .string("command"), "timeout": .number(3), "command": .string("[ -n \"$TRANO_LAUNCH_ID\" ] && \"$TRANO_CLI_PATH\" hook " + provider.rawValue + " || true")])])])]))
        })
    }

    public func integratingAgentHooks(_ plan: AccountCommand, provider: AgentKind) throws -> AccountCommand {
        var command = plan
        if let path = plan.environment[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"],
           try state().accounts.contains(where: { $0.provider == provider && root.appendingPathComponent("accounts").appendingPathComponent($0.id).path == path }),
           FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".trano-account").path) { return command }
        let hooks = Self.activityHooks(provider)
        if provider == .claude {
            let base = try ManagedDirectory.ensure(root, component: "integration")
            let plugin = try ManagedDirectory.ensure(base, component: "claude")
            let manifest = try ManagedDirectory.ensure(plugin, component: ".claude-plugin")
            let directory = try ManagedDirectory.ensure(plugin, component: "hooks")
            let files = [manifest.appendingPathComponent("plugin.json"): "{\"name\":\"trano-session\",\"version\":\"0.1.0\"}\n",
                         directory.appendingPathComponent("hooks.json"): try Self.prettyJSON(.object(["hooks": .object(hooks)]))]
            for (path, value) in files where (try? String(contentsOf: path, encoding: .utf8)) != value { try Self.atomicWrite(Data(value.utf8), to: path) }
            command.arguments += ["--plugin-dir", plugin.path]
        } else {
            command.arguments.insert(contentsOf: ["--no-daemon", "-c", "hooks=" + (try Self.toml(.object(hooks)))], at: 1)
        }
        return command
    }
    private static let codexEvents: Set<String> = ["PreModelRequest", "PostModelRequest", "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "UserPromptSubmit", "Stop", "Interrupt"]
    private static func hasUnsupportedCodexHook(_ value: JSONValue) -> Bool {
        (value["hooks"]?.array ?? []).contains { !["command", "mcp_tool"].contains($0["type"]?.text ?? "") }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func prettyJSON(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
    private static func toml(_ value: JSONValue) throws -> String {
        switch value {
        case .object(let fields): return "{ " + (try fields.keys.sorted().map { try toml(.string($0)) + " = " + toml(fields[$0]!) }).joined(separator: ", ") + " }"
        case .array(let values): return "[" + (try values.map(toml)).joined(separator: ", ") + "]"
        case .null: throw TerminalError.invalid("TOML does not accept null")
        default:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
    }
}

extension JSONValue {
    var array: [JSONValue]? { if case .array(let values) = self { return values }; return nil }
}
