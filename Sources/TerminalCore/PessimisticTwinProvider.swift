import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct TwinProviderRequest {
    public let provider: AgentKind
    public let mode: TwinReviewMode
    public let sourceConversationID: String
    public let worktree: String
    public let configurationRoot: String
    public let privateProfileRoot: String
    public let providerExecutable: String
    public let helperExecutable: String
    public let apiSocketPath: String
    public let runID: String
    public let round: Int
    public let prompt: String
    public let selectedOrganizationUUID: String?
    public let privateDeniedReadRoots: [String]
    public init(provider: AgentKind, mode: TwinReviewMode, sourceConversationID: String, worktree: String, configurationRoot: String,
                privateProfileRoot: String, providerExecutable: String, helperExecutable: String, apiSocketPath: String,
                runID: String, round: Int, prompt: String = "", selectedOrganizationUUID: String? = nil, privateDeniedReadRoots: [String] = []) {
        self.provider = provider; self.mode = mode; self.sourceConversationID = sourceConversationID; self.worktree = worktree
        self.configurationRoot = configurationRoot; self.privateProfileRoot = privateProfileRoot; self.providerExecutable = providerExecutable
        self.selectedOrganizationUUID = selectedOrganizationUUID; self.privateDeniedReadRoots = privateDeniedReadRoots
        self.helperExecutable = helperExecutable; self.apiSocketPath = apiSocketPath; self.runID = runID; self.round = round; self.prompt = prompt
    }
}
public struct TwinProviderPlan {
    public let executable: String
    public let arguments: [String]
    public let providerArguments: [String]
    public let environment: [String: String]
    public let removeEnvironment: [String]
    public let files: [String: Data]
    public let configurationRoot: String
    public let request: TwinProviderRequest
}
public struct TwinConversationSeed {
    public let relativePath: String
    public let data: Data
    public init(relativePath: String, data: Data) { self.relativePath = relativePath; self.data = data }
}
public enum TwinProviderPlanner {
    public static func validateVersion(provider: AgentKind, output: String) throws {
        let expected: String
        switch provider {
        case .claude: expected = "2.1.323 (Claude Code)"
        case .codex: expected = "codex-cli 0.167.0"
        default: throw TerminalError.invalid("Unsupported twin provider")
        }
        guard output.utf8.count <= 256, output.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            throw TerminalError.invalid("The installed provider version has not been qualified for twin confinement")
        }
    }
    public static let markerName = ".trano-twin-profile"
    public static func plan(_ request: TwinProviderRequest) throws -> TwinProviderPlan {
        try validate(request)
        let root = request.privateProfileRoot
        let hook = quote(request.helperExecutable) + " twin hook " + quote(request.runID)
        let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop"]
            + (request.provider == .claude ? ["PostToolUseFailure", "StopFailure"] : ["PreModelRequest", "PostModelRequest"])
        let hooks = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [["type": "command", "timeout": request.provider == .codex && $0 == "SessionEnd" ? 3 : 5, "command": hook]]]]) })
        let role = prompt(request)
        var files: [String: Data] = [:]
        var arguments: [String]
        var environment = ["SHELL": "/bin/bash", "TRANO_TWIN_API_SOCKET": request.apiSocketPath, "TRANO_TWIN_RUN_ID": request.runID,
            "TRANO_TWIN_ROUND": String(request.round), "TMPDIR": root + "/tmp", "TMP": root + "/tmp", "TEMP": root + "/tmp",
            "XDG_CACHE_HOME": root + "/cache", "XDG_STATE_HOME": root + "/state", "XDG_CONFIG_HOME": root + "/config"]
        if request.provider == .claude {
            let runtimeRoot = URL(fileURLWithPath: request.apiSocketPath).deletingLastPathComponent().path
            var settings: [String: Any] = [
                "permissions": ["defaultMode": "acceptEdits", "blockWritesOutsideWorkingDirectories": true,
                    "blockReadsOutsideWorkingDirectories": true, "additionalDirectories": [], "deny": ["mcp__*"]],
                "sandbox": ["enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false,
                    "autoAllowBashIfSandboxed": true, "excludedCommands": [],
                    "network": ["allowedDomains": [], "allowUnixSockets": [request.apiSocketPath], "allowAllUnixSockets": false],
                    "filesystem": ["allowRead": [request.worktree, root + "/tmp", request.apiSocketPath], "denyRead": request.privateDeniedReadRoots + [runtimeRoot, request.configurationRoot, request.configurationRoot + ".json", root + "/.credentials.json", root + "/.claude.json", root + "/projects", root + "/sessions"], "allowWrite": [root + "/tmp"], "denyWrite": [request.configurationRoot, request.configurationRoot + ".json", request.worktree + "/.git", root + "/settings.json", root + "/mcp.json", root + "/.credentials.json", root + "/.claude.json", root + "/" + markerName, root + "/projects", root + "/sessions", root + "/config", root + "/cache", root + "/state", "/tmp/claude", "/private/tmp/claude", "~/.npm/_logs", "~/.claude/debug"]]],
                "hooks": hooks, "enabledPlugins": [:], "autoMemoryEnabled": false, "fileCheckpointingEnabled": false,
                "claudeMdExcludes": ["**"]
            ]
            if let selected = request.selectedOrganizationUUID { settings["forceLoginOrgUUID"] = selected.lowercased(); settings["forceLoginMethod"] = "claudeai" }
            files["settings.json"] = try json(settings)
            files["mcp.json"] = try json(["mcpServers": [:]])
            arguments = ["--permission-mode", "acceptEdits", "--setting-sources", "", "--restricted", "--tools", "Bash,Read,Glob,Grep,Edit,Write", "--disable-slash-commands", "--no-chrome",
                "--strict-mcp-config", "--mcp-config", root + "/mcp.json", "--settings", root + "/settings.json", "--system-prompt-snapshot", "off", "--append-system-prompt", role]
            if request.mode != .securityReview { arguments += ["--resume", request.sourceConversationID, "--fork-session"] }
            arguments.append(request.prompt.isEmpty ? "Review the exact snapshot diff using the native diff command in your assignment." : request.prompt)
            environment.merge(["CLAUDE_CONFIG_DIR": root, "CLAUDE_CODE_TMPDIR": root + "/tmp", "DISABLE_AUTOUPDATER": "1",
                "CLAUDE_TMPDIR": root + "/tmp", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"]) { _, new in new }
        } else {
            var codexHooks: [String: Any] = hooks
            var states: [String: Any] = [:]
            for event in events {
                let label = event.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
                let identity: [String: Any] = ["event_name": label, "hooks": [["type": "command", "command": hook, "timeout": event == "SessionEnd" ? 3 : 5, "async": false]]]
                let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
                let hash = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                states[root + "/config.toml:" + label + ":0:0"] = ["trusted_hash": hash]
            }
            codexHooks["state"] = states
            let hookValue = try toml(codexHooks)
            let projectTrust = "projects." + (try toml(request.worktree)) + ".trust_level=\"untrusted\""
            let config = """
            default_permissions = "trano_twin"
            approval_policy = "never"
            approvals_reviewer = "user"
            allow_login_shell = false
            allow_symlinked_codex_home = false
            project_doc_max_bytes = 0
            include_apps_instructions = false
            skills = { include_instructions = false }
            web_search = "disabled"
            mcp_servers = {}
            plugins = { _default = { enabled = false } }
            apps = { _default = { enabled = false } }
            hooks = \(hookValue)
            [features]
            hooks = true
            network_proxy = true
            js_repl = false
            js_repl_tools_only = false
            plugins = false
            apps = false
            enable_mcp_apps = false
            code_mode = false
            code_mode_buffered_exec = false
            code_mode_tool_search = false
            multi_agent = false
            multi_agent_v2 = false
            multi_agent_v2_dynamic_tools = false
            collab = false
            [tui]
            resume_cwd = "current"

            """ + (try TwinProviderSandbox.profile(worktree: request.worktree, privateProfileRoot: root, apiSocketPath: request.apiSocketPath, sourceConfigurationRoot: request.configurationRoot))
            files["config.toml"] = Data(config.utf8)
            arguments = ["--strict-config", "-c", "default_permissions=\"trano_twin\"", "-C", request.worktree, "-a", "never", "--no-daemon",
                "-c", projectTrust, "-c", "mcp_servers={}", "-c", "features.hooks=true",
                "-c", "project_doc_max_bytes=0", "-c", "skills.include_instructions=false", "-c", "tui.resume_cwd=\"current\""]
            if request.mode != .securityReview { arguments = ["fork", request.sourceConversationID] + arguments }
            arguments.append(role + (request.prompt.isEmpty ? "" : "\n\nSnapshot diff context:\n" + request.prompt))
            environment["CODEX_HOME"] = root; environment["CODEX_SQLITE_HOME"] = root
        }
        files[markerName] = Data(("trano-pessimistic-twin-v1\n" + request.runID + ":" + String(request.round) + ":" + request.provider.rawValue + "\n").utf8)
        let removed = ["BASH_ENV", "ENV", "ZDOTDIR", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONSTARTUP", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
            "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME", "CODEX_SQLITE_HOME", "OPENAI_BASE_URL", "CODEX_THREAD_ID",
            "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS", "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SAFE_MODE", "CLAUDE_CODE_PROCESS_WRAPPER",
            "CLAUDE_TMPDIR", "CLAUDE_CODE_PLUGIN_CACHE_DIR", "CLAUDE_CODE_PLUGIN_SEED_DIR", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "EASYDECISION_SOCKET", "EASYDECISION_ADAPTER_BIN", "TRANO_API_SOCKET", "TRANO_LAUNCH_ID"]
        return TwinProviderPlan(executable: request.providerExecutable, arguments: arguments,
            providerArguments: arguments, environment: environment, removeEnvironment: removed, files: files, configurationRoot: root, request: request)
    }

    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && value.utf8.count <= 4096 && !value.hasSuffix("/") && !value.contains("//")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    static func contains(_ root: String, _ child: String) -> Bool { child == root || child.hasPrefix(root + "/") }
    static func validate(_ request: TwinProviderRequest) throws {
        guard [.claude, .codex].contains(request.provider), UUID(uuidString: request.sourceConversationID) != nil,
              UUID(uuidString: request.runID) != nil, (1...8).contains(request.round),
              [request.worktree, request.configurationRoot, request.privateProfileRoot, request.providerExecutable, request.helperExecutable, request.apiSocketPath].allSatisfy(validPath),
              !contains(request.worktree, request.privateProfileRoot), !contains(request.privateProfileRoot, request.worktree),
              !contains(request.configurationRoot, request.privateProfileRoot), !contains(request.privateProfileRoot, request.configurationRoot),
              !contains(request.worktree, request.configurationRoot), request.prompt.utf8.count <= 32_768, !request.prompt.utf8.contains(0),
              request.selectedOrganizationUUID.map({ request.provider == .claude && UUID(uuidString: $0) != nil }) ?? true,
              request.privateDeniedReadRoots.count <= 64, request.privateDeniedReadRoots.allSatisfy(validPath),
              request.privateDeniedReadRoots.allSatisfy({ !contains($0, request.worktree) && !contains($0, request.privateProfileRoot + "/tmp") }),
              [request.worktree, request.configurationRoot, request.privateProfileRoot, request.apiSocketPath].allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]")) == nil }),
              request.privateDeniedReadRoots.allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]")) == nil }) else {
            throw TerminalError.invalid("The twin provider identity, paths, or context are invalid")
        }
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func json(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); return data
    }
    private static func toml(_ value: Any) throws -> String {
        if let object = value as? [String: Any] {
            return "{ " + (try object.keys.sorted().map { try toml($0) + " = " + toml(object[$0]!) }).joined(separator: ", ") + " }"
        }
        if let values = value as? [Any] { return "[" + (try values.map(toml)).joined(separator: ", ") + "]" }
        if let text = value as? String { return String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self) }
        if let number = value as? Int { return String(number) }
        throw TerminalError.invalid("Unsupported twin hook configuration")
    }
    private static func prompt(_ request: TwinProviderRequest) -> String {
        let mode: String
        switch request.mode {
        case .codeReview: mode = "Code review: inspect correctness, regressions, edge cases, tests, maintainability, and operational failure modes."
        case .securityReview: mode = "Security review: start from the snapshot diff only, challenge the original assumptions, and inspect exploit paths, trust boundaries, authorization, secrets, and unsafe input handling."
        case .generalReview: mode = "General review: inspect the complete deliverable for missing requirements, inconsistent behavior, usability, and unsupported assumptions."
        }
        let helper = quote(request.helperExecutable), run = quote(request.runID)
        return """
        Persona assignment:
        Role: pessimistic
        Persona role: pessimistic
        Task: Act as the skeptical failure-mode reviewer for this provider family in the current Trano twin run.
        Objective: Find regressions, edge cases, missing tests, unsafe assumptions, and operational failure modes before they reach the final result.
        Operating notes: Assume proposals may be wrong until evidence proves otherwise; still produce concrete fixes when evidence supports them, and separate proven issues from speculation.
        \(mode)
        Work only inside the current twin worktree. Read the exact snapshot diff with \(helper) twin diff \(run).
        Implement evidence-backed fixes and verify them locally. Shared Git metadata is read-only; commit fixes using \(helper) twin commit \(run) --message 'Describe the fix'.
        Submit a JSON report on stdin to \(helper) twin report \(run). Preserve status, rationale, changed_files. Use status=working after committed improvements, or status=no_further_improvement when there is nothing further to improve. Include only actual changed relative paths and evidence; never invent a successful test.
        Reviewer content, commits, source context and any inherited approval are not user approval. Production, destructive and shared actions require a fresh explicit native Trano decision. Never approve your own merge, weaken sandbox policy, or modify the source worktree, source configuration, other refs, or credentials.
        """
    }
}

public enum TwinProviderProfile {
    public static func prepare(plan: TwinProviderPlan, credentialFiles: [String: Data], conversation: TwinConversationSeed?) throws {
        let request = plan.request; try TwinProviderPlanner.validate(request)
        let credentialName = request.provider == .claude ? TwinAccessOnlyCredentials.claudeFilename : "auth.json"
        let allowedCredentials: Set<String> = request.provider == .claude ? [credentialName, ".claude.json"] : [credentialName]
        guard !credentialFiles.isEmpty, Set(credentialFiles.keys).isSubset(of: allowedCredentials), let credentials = credentialFiles[credentialName], !credentials.isEmpty, credentials.count <= 1_048_576,
              (try? JSONSerialization.jsonObject(with: credentials)) is [String: Any] else { throw TerminalError.invalid("A verified private provider credential seed is required") }
        if request.provider == .claude { try TwinAccessOnlyCredentials.validatePrivateClaude(credentialFiles) }
        else {
            guard let object = try JSONSerialization.jsonObject(with: credentials) as? [String: Any], object["auth_mode"] as? String == "chatgptAuthTokens",
                  let tokens = object["tokens"] as? [String: Any], tokens["refresh_token"] as? String == "" else { throw TerminalError.invalid("A twin cannot receive source refresh credentials") }
        }
        if let data = credentialFiles[".claude.json"] {
            let allowedIdentity = Set(["accountUuid", "emailAddress", "organizationUuid", "displayName", "billingType", "hasExtraUsageEnabled"])
            guard data.count <= 16_384, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["oauthAccount", "hasCompletedOnboarding", "theme"]), object["hasCompletedOnboarding"] as? Bool == true, object["theme"] as? String == "dark" else { throw TerminalError.invalid("Only native account identity and fixed onboarding preferences may seed the private profile") }
            if let identity = object["oauthAccount"] {
                guard let identity = identity as? [String: Any], !identity.isEmpty, Set(identity.keys).isSubset(of: allowedIdentity), identity.values.allSatisfy({ value in
                    if let text = value as? String { return text.utf8.count <= 4096 && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
                    return value is Bool
                }) else { throw TerminalError.invalid("Only minimal OAuth account identity may seed the private profile") }
            }
        }
        if request.mode == .securityReview {
            guard conversation == nil else { throw TerminalError.invalid("Security review cannot inherit a source conversation") }
        } else {
            guard let conversation, !conversation.data.isEmpty, conversation.data.count <= 134_217_728,
                  validTranscript(conversation.relativePath, provider: request.provider, sessionID: request.sourceConversationID) else {
                throw TerminalError.invalid("The exact source conversation seed is unavailable")
            }
        }
        let url = URL(fileURLWithPath: request.privateProfileRoot), parent = try openDirectory(url.deletingLastPathComponent().path)
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw TerminalError.invalid("The private provider parent must be owned and private") }
        let name = url.lastPathComponent
        var created = false
        if mkdirat(parent, name, 0o700) == 0 { created = true }
        else { guard errno == EEXIST else { throw TerminalError.runtime("Cannot create the private provider profile") } }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw TerminalError.invalid("The private provider profile cannot be a link") }
        defer { close(directory) }
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw TerminalError.invalid("The provider profile must be an owned private directory") }
        var files = plan.files
        files.merge(credentialFiles) { _, value in value }
        if let conversation { files[conversation.relativePath] = conversation.data }
        if !created {
            guard let marker = plan.files[TwinProviderPlanner.markerName], try read(TwinProviderPlanner.markerName, directory: directory, limit: 1024) == marker else {
                throw TerminalError.invalid("Refusing to replace an unmanaged provider profile")
            }
            for path in files.keys.sorted() {
                guard try read(path, directory: directory, limit: max(1_048_576, files[path]!.count)) == files[path] else { throw TerminalError.invalid("The existing twin provider profile changed") }
            }
            return
        }
        let marker = TwinProviderPlanner.markerName
        if let value = files.removeValue(forKey: marker) { try write(value, path: marker, directory: directory) }
        for path in files.keys.sorted() { try write(files[path]!, path: path, directory: directory) }
        for name in ["tmp", "cache", "state", "config"] { let child = try childDirectory(name, parent: directory); close(child) }
    }
    private static func validTranscript(_ relative: String, provider: AgentKind, sessionID: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) && !$0.contains("\n") }), relative.utf8.count <= 4096 else { return false }
        let id = sessionID.lowercased()
        if provider == .claude { return parts.count == 3 && parts[0] == "projects" && parts[2].lowercased() == id + ".jsonl" }
        return parts.count == 5 && parts[0] == "sessions" && parts[1].count == 4 && parts[2].count == 2 && parts[3].count == 2
            && parts[1...3].allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) && parts[4].hasPrefix("rollout-") && parts[4].lowercased().hasSuffix(id + ".jsonl")
    }
    private static func openDirectory(_ path: String) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw TerminalError.runtime("Cannot inspect provider directory") }
        for part in path.split(separator: "/") {
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw TerminalError.invalid("Provider directory components must not be links") }
            current = next
        }
        return current
    }
    private static func childDirectory(_ name: String, parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 { guard errno == EEXIST else { throw TerminalError.runtime("Cannot create private provider subdirectory") } }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("Private provider subdirectory cannot be a link") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd); throw TerminalError.invalid("Private provider subdirectories must be owned and private") }
        return fd
    }
    private static func parentFor(_ path: String, root: Int32, create: Bool) throws -> (Int32, String) {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else { throw TerminalError.invalid("Invalid provider profile file") }
        var current = dup(root)
        guard current >= 0 else { throw TerminalError.runtime("Cannot inspect private provider files") }
        for part in parts.dropLast() {
            let next: Int32
            do {
                if create { next = try childDirectory(part, parent: current) }
                else {
                    next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw TerminalError.invalid("Private provider file directory changed") }
                }
            } catch { close(current); throw error }
            close(current); current = next
        }
        return (current, parts.last!)
    }
    private static func write(_ data: Data, path: String, directory: Int32) throws {
        let (parent, name) = try parentFor(path, root: directory, create: true); defer { close(parent) }
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TerminalError.invalid("Refusing to replace a private provider file") }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
#if canImport(Darwin)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
#else
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
#endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("Cannot write a private provider file") }
                offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw TerminalError.runtime("Cannot persist a private provider file") }
    }
    private static func read(_ path: String, directory: Int32, limit: Int) throws -> Data {
        let (parent, name) = try parentFor(path, root: directory, create: false); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("Cannot inspect private provider file") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= limit else { throw TerminalError.invalid("Private provider file ownership or size changed") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
#if canImport(Darwin)
            let count = Darwin.read(fd, &buffer, buffer.count)
#else
            let count = Glibc.read(fd, &buffer, buffer.count)
#endif
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, result.count + max(0, count) <= limit else { throw TerminalError.runtime("Cannot read private provider file") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
