import XCTest
@testable import TerminalCore

final class AccountManagementTests: XCTestCase {
    private func runtime() throws -> TerminalRuntime {
        try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-ac-" + UUID().uuidString.prefix(8)))
    }

    // Implements: FR-ACCOUNT-1, FR-ACCOUNT-2
    func testProfileMutationPreservesOrderAndRejectsInvalidRegistryChanges() throws {
        let runtime = try runtime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let first = try runtime.addAccount(provider: .claude, label: "Work")
        let second = try runtime.addAccount(provider: .codex, label: "Personal")
        try runtime.updateAccount(first.id, label: "작업", enabled: false, pinned: true)
        try runtime.reorderAccounts([second.id, first.id])
        let state = try runtime.state()
        XCTAssertEqual(state.accounts.map(\.id), [second.id, first.id])
        XCTAssertEqual(state.accounts.last?.label, "작업")
        XCTAssertEqual(state.accounts.last?.enabled, false)
        XCTAssertEqual(state.accounts.last?.pinned, true)
        XCTAssertThrowsError(try runtime.reorderAccounts([first.id, first.id]))
        XCTAssertThrowsError(try runtime.updateAccount(first.id, label: "\n"))
        XCTAssertThrowsError(try runtime.accountCommand(first.id))
        XCTAssertTrue(try runtime.accountCommand(second.id).arguments.contains("--no-daemon"))
    }

    // Implements: FR-ACCOUNT-2
    func testClaudeUsageOnlyAcceptsStructuredQuotaAndDiscardsExpiredWindows() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let parsed = try AccountUsageAdapter.claude(accountID: "a", data: Data(#"{"rate_limits":{"five_hour":{"used_percentage":100,"resets_at":2000000060},"seven_day":{"used_percentage":40.5,"resets_at":2000100000},"spend_limit":{"used_percentage":100,"resets_at":1999999999}},"context_window":{"used_percentage":99}}"#.utf8), now: now)
        XCTAssertEqual(parsed.status, .limited)
        XCTAssertEqual(parsed.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(parsed.retryAt, now.addingTimeInterval(60))
        let unknown = try AccountUsageAdapter.claude(accountID: "a", data: Data(#"{"context_window":{"used_percentage":100},"error":"rate limit reached"}"#.utf8), now: now)
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertNil(unknown.retryAt)
        XCTAssertThrowsError(try AccountUsageAdapter.claude(accountID: "a", data: Data(#"{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":2000000060}}}"#.utf8), now: now))
    }

    // Implements: FR-ACCOUNT-2
    func testCodexUsageHonorsBackendPermissionAndNeverInfersRecoveryFromReset() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let payload = #"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":2,"resetsAt":1999999999},"secondary":{"usedPercent":30,"resetsAt":2000000060},"rateLimitReachedType":"rate_limit_reached"}}"#
        let parsed = try AccountUsageAdapter.codex(accountID: "c", data: Data(payload.utf8), now: now)
        XCTAssertEqual(parsed.status, .limited)
        XCTAssertNil(parsed.retryAt)
        let allowed = try AccountUsageAdapter.codex(accountID: "c", data: Data(#"{"ordinaryUsageAllowed":true,"rateLimits":{"primary":{"usedPercent":100,"resetsAt":2000000060}}}"#.utf8), now: now)
        XCTAssertEqual(allowed.status, .available)
        XCTAssertNil(allowed.retryAt)
        let absent = try AccountUsageAdapter.codex(accountID: "c", data: Data(#"{"rateLimits":{}}"#.utf8), now: now)
        XCTAssertEqual(absent.status, .unknown)
    }

    // Implements: FR-ACCOUNT-1, FR-ACCOUNT-2
    func testAuthenticationStatusRequiresOwnedProfileAndNeverImpliesQuota() throws {
        let account = AccountProfile(provider: .claude, label: "Test")
        let root = URL(fileURLWithPath: "/tmp/trano-auth-fixture")
        let loggedIn = Data(#"{"loggedIn":true,"authMethod":"claude.ai","configDirectory":"/tmp/trano-auth-fixture","email":"discard@example.test"}"#.utf8)
        let result = try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0, data: loggedIn)
        XCTAssertEqual(result.status, .authenticated)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("discard@example.test"))
        let wrongRoot = Data(#"{"loggedIn":true,"authMethod":"claude.ai","configDirectory":"/tmp/another-profile"}"#.utf8)
        XCTAssertEqual(try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0, data: wrongRoot).status, .unknown)
        XCTAssertEqual(try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 1, data: loggedIn).status, .unknown)
    }

    // Implements: FR-ACCOUNT-1
    func testInstalledClaudeAuthenticationStaysInsideEmptyManagedProfile() throws {
        guard ProcessInfo.processInfo.environment["TRANO_TEST_INSTALLED_CLAUDE"] == "1" else { throw XCTSkip("Set TRANO_TEST_INSTALLED_CLAUDE=1 for the installed provider compatibility gate") }
        let runtime = try runtime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let account = try runtime.addAccount(provider: .claude, label: "Empty isolated profile")
        XCTAssertEqual(try runtime.accountAuthentication(accountID: account.id).status, .loggedOut)
        XCTAssertEqual(try runtime.accountUsage().first?.status, .unknown)
        let command = try runtime.accountCommand(account.id, arguments: ["auth", "status", "--json"])
        var environment = ProcessInfo.processInfo.environment
        for key in command.removeEnvironment { environment.removeValue(forKey: key) }
        environment.merge(command.environment) { _, new in new }
        let response = try CommandRunner.run(command.executable, command.arguments, environment: environment, timeout: 10)
        XCTAssertEqual(response.status, 1)
        let payload = try AccountUsageAdapter.object(response.stdout)
        XCTAssertEqual(payload["loggedIn"] as? Bool, false)
    }

    // Implements: FR-ACCOUNT-2
    func testClaudeTransferIsExactPrivateAndRollbackRestoresTarget() throws {
        let runtime = try runtime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let source = try runtime.addAccount(provider: .claude, label: "First")
        let target = try runtime.addAccount(provider: .claude, label: "Second")
        let paneID = UUID().uuidString.lowercased(), sessionID = UUID().uuidString.lowercased()
        let sourceRoot = try runtime.accountRoot(source.id), targetRoot = try runtime.accountRoot(target.id)
        let projects = sourceRoot.appendingPathComponent("projects/-tmp-work")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let contents = Data(("{\"sessionId\":\"\(sessionID)\",\"cwd\":\"/tmp\",\"type\":\"user\",\"message\":{\"content\":\"private synthetic conversation\"}}\n").utf8)
        try contents.write(to: projects.appendingPathComponent(sessionID + ".jsonl"))
        try Data("do not copy".utf8).write(to: sourceRoot.appendingPathComponent(".credentials.json"))
        try Data("target credentials".utf8).write(to: targetRoot.appendingPathComponent(".credentials.json"))
        let launch = AgentLaunch(paneID: paneID, provider: .claude, providerSessionID: sessionID, cwd: "/tmp", accountID: source.id, configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update { state in
            state.sessions.append(TerminalSession(id: paneID, title: "Test", cwd: "/tmp", pid: 0))
            state.agentLaunches.append(launch)
        }
        XCTAssertThrowsError(try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: true, safeTurnBoundary: true))
        XCTAssertThrowsError(try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: "stale", toolsInFlight: false, safeTurnBoundary: true))
        XCTAssertThrowsError(try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: false))
        let plan = try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true)
        let receipt = try runtime.transferAccountSession(plan)
        let copied = targetRoot.appendingPathComponent("projects/-tmp-work/" + sessionID + ".jsonl")
        XCTAssertEqual(try Data(contentsOf: copied), contents)
        XCTAssertEqual(try String(contentsOf: targetRoot.appendingPathComponent(".credentials.json"), encoding: .utf8), "target credentials")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try runtime.rollbackAccountTransfer(receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(try Data(contentsOf: projects.appendingPathComponent(sessionID + ".jsonl")), contents)
        try runtime.recordAgentProcess(paneID: paneID, generation: launch.id, pid: getpid())
        let livePlan = try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true)
        XCTAssertThrowsError(try runtime.transferAccountSession(livePlan))
        try runtime.recordAgentProcess(paneID: paneID, generation: launch.id, pid: getpid() + 1)
        XCTAssertThrowsError(try runtime.validateAccountSwitch(livePlan))
    }

    // Implements: FR-ACCOUNT-2
    func testTransferRefusesSymlinksAndUnrelatedSessionContent() throws {
        let runtime = try runtime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let source = try runtime.addAccount(provider: .codex, label: "First")
        let target = try runtime.addAccount(provider: .codex, label: "Second")
        let sourceRoot = try runtime.accountRoot(source.id)
        let paneID = UUID().uuidString.lowercased(), sessionID = UUID().uuidString.lowercased()
        let directory = sourceRoot.appendingPathComponent("sessions/2026/11/11")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("rollout-2026-11-11T00-00-00-" + sessionID + ".jsonl")
        try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(UUID().uuidString)\",\"cwd\":\"/tmp\"}}\n").utf8).write(to: rollout)
        let launch = AgentLaunch(paneID: paneID, provider: .codex, providerSessionID: sessionID, cwd: "/tmp", accountID: source.id, configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update { $0.sessions.append(TerminalSession(id: paneID, title: "Test", cwd: "/tmp", pid: 0)); $0.agentLaunches.append(launch) }
        XCTAssertThrowsError(try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true))
        try FileManager.default.removeItem(at: rollout)
        try FileManager.default.createSymbolicLink(at: rollout, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true))
    }

    // Implements: FR-ACCOUNT-2
    func testCodexTransferCopiesOneMetadataRowAndRestoresItOnRollback() throws {
        let runtime = try runtime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let source = try runtime.addAccount(provider: .codex, label: "Source")
        let target = try runtime.addAccount(provider: .codex, label: "Target")
        let sourceRoot = try runtime.accountRoot(source.id), targetRoot = try runtime.accountRoot(target.id)
        let sid = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased()
        let relative = "sessions/2026/11/11/rollout-2026-11-11T00-00-00-" + sid + ".jsonl"
        let file = try AccountSessionFiles.path(relative, beneath: sourceRoot, createParents: true)
        try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sid)\",\"cwd\":\"/tmp\"}}\n").utf8).write(to: file)
        let schema = "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT);"
        for directory in [sourceRoot, targetRoot] {
            let result = try CommandRunner.run("/usr/bin/sqlite3", [directory.appendingPathComponent("state_5.sqlite").path], input: Data(schema.utf8))
            XCTAssertEqual(result.status, 0)
        }
        _ = try CommandRunner.run("/usr/bin/sqlite3", [sourceRoot.appendingPathComponent("state_5.sqlite").path], input: Data("INSERT INTO threads VALUES ('\(sid)', '\(file.path)', '/tmp', 'selected'); INSERT INTO threads VALUES ('unrelated', '/private/other', '/tmp', 'never copied');".utf8))
        _ = try CommandRunner.run("/usr/bin/sqlite3", [targetRoot.appendingPathComponent("state_5.sqlite").path], input: Data("INSERT INTO threads VALUES ('\(sid)', '/old', '/tmp', 'previous'); INSERT INTO threads VALUES ('target-only', '/target', '/tmp', 'keep');".utf8))
        let cacheTables = ["thread_items", "thread_turns", "thread_realtime_items", "thread_history_projection_state"]
        let cacheSQL = cacheTables.map { "CREATE TABLE \($0)(thread_id TEXT, payload TEXT); INSERT INTO \($0) VALUES ('\(sid)', 'old cache'); INSERT INTO \($0) VALUES ('target-only', 'keep cache');" }.joined(separator: "\n")
        XCTAssertEqual(try CommandRunner.run("/usr/bin/sqlite3", [targetRoot.appendingPathComponent("thread_history_1.sqlite").path], input: Data(cacheSQL.utf8)).status, 0)
        let launch = AgentLaunch(paneID: pane, provider: .codex, providerSessionID: sid, cwd: "/tmp", accountID: source.id, configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Test", cwd: "/tmp", pid: 0)); $0.agentLaunches.append(launch) }
        let plan = try runtime.prepareAccountSwitch(paneID: pane, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true)
        let receipt = try runtime.transferAccountSession(plan)
        XCTAssertNotNil(receipt.database?.previousDigest)
        let historyReceipt = runtime.root.appendingPathComponent("account-transfers/" + receipt.id + "/history-transfer.json")
        let historyProof = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: historyReceipt))
        XCTAssertEqual(historyProof["sessionID"]?.text, sid)
        XCTAssertEqual(Set(historyProof["installedDigests"].flatMap { value -> [String]? in
            if case .object(let values) = value { return Array(values.keys) }
            return nil
        } ?? []), Set(cacheTables))
        let installed = try CommandRunner.run("/usr/bin/sqlite3", [targetRoot.appendingPathComponent("state_5.sqlite").path, "SELECT id || ':' || title FROM threads ORDER BY id"])
        let text = String(decoding: installed.stdout, as: UTF8.self)
        XCTAssertTrue(text.contains(sid + ":selected")); XCTAssertTrue(text.contains("target-only:keep")); XCTAssertFalse(text.contains("unrelated"))
        let cache = try CommandRunner.run("/usr/bin/sqlite3", [targetRoot.appendingPathComponent("thread_history_1.sqlite").path, "SELECT thread_id FROM thread_items"])
        XCTAssertEqual(String(decoding: cache.stdout, as: UTF8.self), "target-only\n")
        try runtime.rollbackAccountTransfer(receipt)
        let restored = try CommandRunner.run("/usr/bin/sqlite3", [targetRoot.appendingPathComponent("state_5.sqlite").path, "SELECT title FROM threads WHERE id = '\(sid)'"])
        XCTAssertEqual(String(decoding: restored.stdout, as: UTF8.self), "previous\n")
        let restoredCache = try CommandRunner.run("/usr/bin/sqlite3", [targetRoot.appendingPathComponent("thread_history_1.sqlite").path, "SELECT payload FROM thread_items WHERE thread_id = '\(sid)'"])
        XCTAssertEqual(String(decoding: restoredCache.stdout, as: UTF8.self), "old cache\n")
    }

    // Implements: FR-ACCOUNT-2
    func testInstalledCodexReadsTransferredConversationWithoutModelRequest() throws {
        guard ProcessInfo.processInfo.environment["TRANO_TEST_INSTALLED_CODEX"] == "1" else { throw XCTSkip("Set TRANO_TEST_INSTALLED_CODEX=1 for the installed provider compatibility gate") }
        let runtime = try runtime()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let source = try runtime.addAccount(provider: .codex, label: "Source"), target = try runtime.addAccount(provider: .codex, label: "Target")
        XCTAssertEqual(try runtime.refreshAccountUsage(accountID: source.id).status, .authenticationRequired)
        XCTAssertEqual(try runtime.refreshAccountUsage(accountID: target.id).status, .authenticationRequired)
        let sourceRoot = try runtime.accountRoot(source.id), targetRoot = try runtime.accountRoot(target.id)
        let sid = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased()
        let relative = "sessions/2026/11/11/rollout-2026-11-11T00-00-00-" + sid + ".jsonl"
        let file = try AccountSessionFiles.path(relative, beneath: sourceRoot, createParents: true)
        let historyMode = ProcessInfo.processInfo.environment["TRANO_TEST_CODEX_HISTORY"] == "paginated" ? "paginated" : "legacy"
        let items: [[String: Any]] = [
            ["timestamp": "2026-11-11T00:00:00Z", "type": "session_meta", "payload": ["id": sid, "timestamp": "2026-11-11T00:00:00Z", "cwd": "/tmp", "originator": "codex_cli_rs", "cli_version": "0.167.0", "source": "cli", "model_provider": "openai", "history_mode": historyMode, "account_scoped": false]],
            ["timestamp": "2026-11-11T00:00:01Z", "type": "event_msg", "payload": ["type": "task_started", "turn_id": "synthetic-turn", "started_at": 1794355201]],
            ["timestamp": "2026-11-11T00:00:01Z", "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Synthetic transfer fixture"]]]],
            ["timestamp": "2026-11-11T00:00:01Z", "type": "event_msg", "payload": ["type": "user_message", "message": "Synthetic transfer fixture", "images": []]],
            ["timestamp": "2026-11-11T00:00:02Z", "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "synthetic-turn", "completed_at": 1794355202]]
        ]
        var data = Data()
        for (ordinal, entry) in items.enumerated() {
            var item = entry
            if historyMode == "paginated" { item["ordinal"] = ordinal }
            data.append(try JSONSerialization.data(withJSONObject: item)); data.append(10)
        }
        try data.write(to: file)
        let statement = "INSERT INTO threads(id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode,has_user_event,history_mode) VALUES ('\(sid)','\(file.path)',1794355200,1794355201,'cli','openai','/tmp','Synthetic transfer fixture','{\"type\":\"read-only\"}','on-request',1,'\(historyMode)');"
        XCTAssertEqual(try CommandRunner.run("/usr/bin/sqlite3", [sourceRoot.appendingPathComponent("state_5.sqlite").path], input: Data(statement.utf8)).status, 0)
        if historyMode == "paginated" {
            var sourceEnvironment = ProcessInfo.processInfo.environment
            for key in try runtime.accountCommand(source.id).removeEnvironment { sourceEnvironment.removeValue(forKey: key) }
            sourceEnvironment["CODEX_HOME"] = sourceRoot.path
            _ = try AccountRPC.request(method: "thread/turns/list", parameters: .object(["threadId": .string(sid), "limit": .number(1)]), environment: sourceEnvironment)
            let item = #"{"type":"userMessage","id":"synthetic-user","content":[{"type":"text","text":"Synthetic transfer fixture"}]}"#
            let history = "INSERT INTO thread_turns(thread_id,turn_id,rollout_ordinal,status,first_user_item_id) VALUES ('\(sid)','synthetic-turn',1,'completed','synthetic-user'); INSERT INTO thread_items(thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_json,item_type) VALUES ('\(sid)','synthetic-turn','synthetic-user',2,1794355201000,'\(item)','userMessage'); INSERT INTO thread_history_projection_state VALUES ('\(sid)',\(data.count),5);"
            XCTAssertEqual(try CommandRunner.run("/usr/bin/sqlite3", [sourceRoot.appendingPathComponent("thread_history_1.sqlite").path], input: Data(history.utf8)).status, 0)
        }
        let launch = AgentLaunch(paneID: pane, provider: .codex, providerSessionID: sid, cwd: "/tmp", accountID: source.id, configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Test", cwd: "/tmp", pid: 0)); $0.agentLaunches.append(launch) }
        let plan = try runtime.prepareAccountSwitch(paneID: pane, targetAccountID: target.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true)
        let receipt = try runtime.transferAccountSession(plan)
        var environment = ProcessInfo.processInfo.environment
        for key in try runtime.accountCommand(target.id).removeEnvironment { environment.removeValue(forKey: key) }
        environment["CODEX_HOME"] = targetRoot.path
        let response = try AccountRPC.request(method: "thread/read", parameters: .object(["threadId": .string(sid), "includeTurns": .bool(true)]), environment: environment)
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["result"]?["thread"]?["id"]?.text, sid)
        if historyMode == "paginated" {
            let turns = try AccountRPC.request(method: "thread/turns/list", parameters: .object(["threadId": .string(sid), "limit": .number(10), "itemsView": .string("full")]), environment: environment)
            XCTAssertNil(turns["error"])
            XCTAssertEqual(turns["result"]?["data"]?.array?.count, 1)
            XCTAssertTrue(String(decoding: try JSONEncoder().encode(turns), as: UTF8.self).contains("Synthetic transfer fixture"))
        } else { XCTAssertEqual(response["result"]?["thread"]?["turns"]?.array?.count, 1) }
        try runtime.commitAccountTransfer(receipt)
    }
}
