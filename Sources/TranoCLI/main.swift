import Foundation
import TerminalCore

struct Response<T: Encodable>: Encodable {
    let apiVersion = 1
    let result: T
}

func emit<T: Encodable>(_ result: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Response(result: result))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

struct PendingAccountTransfer {
    let plan: AccountSwitchPlan
    let receipt: AccountTransferReceipt
    let source: AgentLaunch

    func isConfirmed(in state: RuntimeState) -> Bool {
        guard let target = state.agentLaunches.first(where: {
            $0.paneID == plan.paneID && $0.id != source.id && $0.accountID == plan.targetAccountID &&
            $0.provider == plan.provider && $0.providerSessionID == plan.providerSessionID
        }) else { return false }
        return state.supervision.contains { $0.generation == target.id && $0.startedSessionID == plan.providerSessionID }
    }
}

struct ProviderAttemptResult {
    let code: Int32
    let next: PendingAccountTransfer?
    let transferConfirmed: Bool
    var interruptedBy: Int32? = nil
}

func runProvider(_ initialPlan: AccountCommand, agent: AgentKind, runtime: TerminalRuntime, accountID: String? = nil, resume: AgentLaunch? = nil) throws -> Int32 {
    var command = initialPlan, account = accountID, recovery = resume
    var transferred: PendingAccountTransfer?
    let relay = ProviderSignalRelay()
    let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
        source.setEventHandler { relay.send(value) }
        source.resume()
        return source
    }
    defer { for source in signals { source.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }
    func rollback(_ transfer: PendingAccountTransfer) throws {
        try runtime.restoreSwitchSource(transfer.source)
        try runtime.rollbackAccountTransfer(transfer.receipt)
    }
    func restoreSource(_ transfer: PendingAccountTransfer) throws {
        guard let sourceAccount = transfer.source.accountID else { throw TerminalError.invalid("Original account is missing") }
        guard FileManager.default.changeCurrentDirectoryPath(transfer.source.cwd) else { throw TerminalError.invalid("Original conversation directory became unavailable") }
        let sourceCommand = try runtime.accountCommand(sourceAccount, arguments: agent == .claude ? ["--resume", transfer.plan.providerSessionID] : ["resume", transfer.plan.providerSessionID])
        try runtime.setRecovery(transfer.source.paneID, status: .restoring, message: "Restoring the original account after target resume failed")
        account = sourceAccount
        recovery = transfer.source
        command = sourceCommand
        transferred = nil
        _ = try? runtime.recordAccountFailure(accountID: transfer.plan.targetAccountID, authentication: false)
        try? runtime.setAccountCooldown(transfer.plan.targetAccountID, until: Date().addingTimeInterval(300))
    }
    while true {
        let result: ProviderAttemptResult
        do {
            if let transferred {
                if let interrupted = relay.lastSignalValue { try rollback(transferred); return 128 + interrupted }
                let next = transferred.plan
                guard FileManager.default.changeCurrentDirectoryPath(next.cwd) else { throw TerminalError.invalid("Conversation directory became unavailable") }
                command = try runtime.accountCommand(next.targetAccountID, arguments: agent == .claude ? ["--resume", next.providerSessionID] : ["resume", next.providerSessionID])
            }
            result = try runProviderAttempt(command, agent: agent, runtime: runtime, accountID: account, resume: recovery,
                                            relay: relay, expectedTransfer: transferred)
        } catch {
            if let transferred {
                if transferred.isConfirmed(in: try runtime.state()) {
                    try? runtime.commitAccountTransfer(transferred.receipt)
                    throw TerminalError.runtime("Target conversation resumed; preserving its current account after an error: " + error.localizedDescription)
                }
                do { try rollback(transferred) }
                catch let rollbackError { throw TerminalError.runtime(error.localizedDescription + "; recovery rollback also failed: " + rollbackError.localizedDescription) }
                if let interrupted = relay.lastSignalValue ?? relay.stoppedSignalValue { return 128 + interrupted }
                try restoreSource(transferred)
                continue
            }
            throw error
        }
        if let pending = transferred {
            if result.transferConfirmed { try runtime.commitAccountTransfer(pending.receipt) }
            else {
                try rollback(pending)
                if let interrupted = result.interruptedBy ?? relay.lastSignalValue { return 128 + interrupted }
                if [128 + SIGINT, 128 + SIGTERM].contains(result.code) { return result.code }
                try restoreSource(pending)
                continue
            }
        }
        guard let next = result.next else { return result.code }
        transferred = next
        account = next.plan.targetAccountID
        recovery = nil
    }
}

func runProviderAttempt(_ initialPlan: AccountCommand, agent: AgentKind, runtime: TerminalRuntime, accountID: String?, resume: AgentLaunch?, relay: ProviderSignalRelay, expectedTransfer: PendingAccountTransfer?) throws -> ProviderAttemptResult {
    let session = ProcessInfo.processInfo.environment["TRANO_SESSION"]
    let nested = !(ProcessInfo.processInfo.environment["TRANO_LAUNCH_ID"] ?? "").isEmpty
    let interactive = AgentInvocation.isInteractive(initialPlan.arguments, provider: agent)
    var plan = initialPlan
    var environment = ProcessInfo.processInfo.environment
    for key in ["REX_BLOCK", "REX_SESSION", "REX_SERVER"] { environment.removeValue(forKey: key) }
    for name in plan.removeEnvironment { environment.removeValue(forKey: name) }
    environment.merge(plan.environment) { _, new in new }
    let shim = runtime.root.appendingPathComponent("bin").path
    environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init).filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != URL(fileURLWithPath: shim).resolvingSymlinksInPath().path }.joined(separator: ":")
    environment.removeValue(forKey: "TRANO_LAUNCH_ID")
    var launch: AgentLaunch?
    if let session, interactive, !nested {
        plan = try runtime.integratingAgentHooks(plan, provider: agent)
        launch = try runtime.beginAgentLaunch(paneID: session, provider: agent, cwd: FileManager.default.currentDirectoryPath,
                                             accountID: accountID, configurationRoot: environment[agent == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"], resume: resume)
        environment["TRANO_LAUNCH_ID"] = launch?.id
        environment["TRANO_CLI_PATH"] = Bundle.main.executableURL?.path
        try runtime.report(session, state: .running, agent: agent, source: "process")
    }
    var argv = ([plan.executable] + plan.arguments).map { strdup($0) } + [nil]
    var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t(), mask = sigset_t()
    sigemptyset(&defaults); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM)
    sigemptyset(&mask)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setpgroup(&attributes, 0)
    let flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED
    posix_spawnattr_setflags(&attributes, Int16(flags))
    let terminal = ProviderTerminalControl()
    var childPID: pid_t = 0
    let spawned = posix_spawn(&childPID, plan.executable, nil, &attributes, &argv, &envp)
    guard spawned == 0 else {
        if let session, let launch { try? runtime.endAgentLaunch(paneID: session, generation: launch.id, normalExit: true); try? runtime.report(session, state: .error, reason: "Launch failed", agent: agent, source: "process") }
        throw TerminalError.runtime("Cannot launch provider: " + String(cString: strerror(spawned)))
    }
    if let session, let launch {
        do { try runtime.recordAgentProcess(paneID: session, generation: launch.id, pid: childPID) }
        catch {
            kill(childPID, SIGKILL)
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
            try? runtime.endAgentLaunch(paneID: session, generation: launch.id, normalExit: true)
            throw error
        }
    }
    relay.setPID(childPID)
    var reaped = false, relayStopped = false
    defer {
        if !relayStopped { _ = relay.stop() }
        if !reaped {
            kill(childPID, SIGKILL)
            var cleanup: Int32 = 0
            while waitpid(childPID, &cleanup, 0) < 0 && errno == EINTR {}
        }
        terminal.restore()
    }
    try terminal.give(to: childPID)
    kill(childPID, SIGCONT)
    var status: Int32 = 0
    let supervisor = launch.map { ProviderSupervisor(runtime: runtime, launch: $0) }
    var switching: AccountSwitchPlan?
    var switchDeadline: TimeInterval?
    var transferConfirmed = expectedTransfer == nil
    while true {
        let waited = waitpid(childPID, &status, WNOHANG)
        if waited == childPID { reaped = true; break }
        if waited < 0 && errno != EINTR { throw TerminalError.runtime("Cannot wait for provider") }
        if let deadline = switchDeadline, ProcessInfo.processInfo.systemUptime > deadline {
            kill(childPID, SIGKILL)
            switchDeadline = nil
        }
        try supervisor?.observeBoundary(with: relay)
        if !transferConfirmed, let transfer = expectedTransfer, let launch,
           try runtime.state().supervision.contains(where: { $0.generation == launch.id && $0.startedSessionID == transfer.plan.providerSessionID }) {
            transferConfirmed = true
        }
        if switching == nil, transferConfirmed, !relay.wasInterrupted, let supervisor {
            do {
                if let plan = try supervisor.pendingSwitch(), !relay.wasInterrupted {
                    try supervisor.stopForSwitch(plan, childPID: childPID)
                    switching = plan
                    switchDeadline = ProcessInfo.processInfo.systemUptime + 5
                }
            } catch {
                try? runtime.recordSwitchMessage(generation: supervisor.launch.id, message: error.localizedDescription, clearRequest: true)
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let interruptedBy = relay.stop()
    relayStopped = true
    terminal.restore()
    if !transferConfirmed, let transfer = expectedTransfer, let launch {
        transferConfirmed = try runtime.state().supervision.contains { $0.generation == launch.id && $0.startedSessionID == transfer.plan.providerSessionID }
    }
    let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    if let switching, let launch, interruptedBy == nil {
        do {
            guard let source = try runtime.state().agentLaunches.first(where: { $0.id == launch.id }) else { throw TerminalError.invalid("Source launch changed") }
            let receipt = try runtime.transferAccountSession(switching)
            try runtime.endAgentLaunch(paneID: launch.paneID, generation: launch.id, normalExit: true)
            try runtime.report(launch.paneID, state: .running, reason: "Resuming with the next account", agent: agent, source: "process")
            return ProviderAttemptResult(code: code, next: PendingAccountTransfer(plan: switching, receipt: receipt, source: source), transferConfirmed: transferConfirmed)
        } catch {
            try? runtime.recordSwitchMessage(generation: launch.id, message: "Account switch failed: " + error.localizedDescription, clearRequest: true)
            try? runtime.report(launch.paneID, state: .blocked, reason: "Account switch failed; the original conversation is preserved", agent: agent, source: "process")
            throw error
        }
    }
    if let session, let launch {
        let paneSurvived = (try? runtime.list().first(where: { $0.id == session })?.alive) == true
        let startedSession = try runtime.state().supervision.first(where: { $0.generation == launch.id })?.startedSessionID
        let resumeConfirmed = resume == nil || startedSession == resume?.providerSessionID
        let normal = resumeConfirmed && paneSurvived && (status & 0x7f == 0 || status & 0x7f == SIGINT) && ![SIGHUP, SIGTERM].contains(interruptedBy ?? 0)
        try runtime.endAgentLaunch(paneID: session, generation: launch.id, normalExit: normal)
        try runtime.report(session, state: code == 0 ? .done : .error, reason: "Exit \(code)", agent: agent, source: "process")
        if resume != nil, try runtime.state().recoveryResults.contains(where: { $0.paneID == session && $0.status == .restoring }) { try runtime.setRecovery(session, status: .failed, message: "Provider exited before confirming conversation resume (exit \(code))") }
    }
    return ProviderAttemptResult(code: code, next: nil, transferConfirmed: transferConfirmed, interruptedBy: interruptedBy)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}

if args.isEmpty || args.first == "--help" || args.first == "help" {
    print("""
    trano API v1
      list [--query TEXT]
      workspaces [--query TEXT]
      launch --cwd PATH [--agent shell|claude|codex] [--prompt TEXT]
      select WORKSPACE_ID
      actions
      do ACTION_ID [--workspace ID] [--tab ID] [--pane ID] [--cwd PATH]
      create [--title TEXT] [--cwd PATH]
      capture ID [--lines 100]
      send ID TEXT [--enter]
      attach ID
      detach ID
      terminate ID
      status ID STATE [--reason TEXT] [--agent shell|claude|codex]
      state
      check
      serve
      api METHOD [PARAMS_JSON]
      run --agent claude|codex -- [PROVIDER_ARGUMENTS]
      account list
      account add --provider claude|codex --label TEXT
      account exec ID [--login] [-- PROVIDER_ARGUMENTS]
      account usage [ID]
      account switch PANE_ID ACCOUNT_ID
      account switching on|off
      extension list
      extension import --kind skill|plugin|hook|mcp --name NAME --path PATH
      extension preview ACCOUNT_ID [EXTENSION_IDS...]
      extension apply PLAN_JSON_FILE
      extension install ACCOUNT_ID EXTENSION_ID
      recovery list
      recovery run [PANE_ID]
    TRANO_DATA_DIR selects an isolated runtime directory. All results are JSON.
    """)
    exit(0)
}

do {
    let runtime = try TerminalRuntime(helperExecutable: Bundle.main.executableURL?.path)
    let command = args.removeFirst()
    switch command {
    case "cwd":
        guard args.count == 2, ProcessInfo.processInfo.environment["TRANO_SESSION"] == args[0] else { throw TerminalError.invalid("cwd requires the current pane and directory") }
        try runtime.recordDirectory(paneID: args[0], cwd: args[1])
    case "recovery":
        guard !args.isEmpty else { throw TerminalError.invalid("recovery requires list or run") }
        switch args.removeFirst() {
        case "list": try emit(runtime.state().recoveryResults)
        case "run":
            guard args.count <= 1 else { throw TerminalError.invalid("recovery run accepts one pane ID") }
            try emit(runtime.recoverSessions(paneID: args.first))
        case "resume":
            guard args.count == 2, ProcessInfo.processInfo.environment["TRANO_SESSION"] == args[0],
                  let launch = try runtime.state().agentLaunches.first(where: { $0.paneID == args[0] && $0.id == args[1] && $0.lifecycle == .active }) else { throw TerminalError.invalid("Recovery launch no longer matches this pane") }
            let plan = try runtime.recoveryCommand(launch)
            guard FileManager.default.changeCurrentDirectoryPath(launch.cwd) else { throw TerminalError.invalid("Original working directory is unavailable") }
            exit(try runProvider(plan, agent: launch.provider, runtime: runtime, accountID: launch.accountID, resume: launch))
        default: throw TerminalError.invalid("Unknown recovery command")
        }
    case "extension":
        guard !args.isEmpty else { throw TerminalError.invalid("extension requires a subcommand") }
        switch args.removeFirst() {
        case "list": try emit(runtime.state().extensions)
        case "import":
            let kind = option("--kind") ?? "", name = option("--name") ?? "", path = option("--path") ?? ""
            guard args.isEmpty, let kind = ExtensionKind(rawValue: kind), !path.isEmpty else { throw TerminalError.invalid("extension import requires --kind, --name and --path") }
            try emit(runtime.importExtension(name: name, kind: kind, source: URL(fileURLWithPath: path)))
        case "preview":
            guard !args.isEmpty else { throw TerminalError.invalid("extension preview requires ACCOUNT_ID") }
            let id = args.removeFirst()
            try emit(runtime.extensionPlan(accountID: id, extensionIDs: args))
        case "apply":
            guard args.count == 1 else { throw TerminalError.invalid("extension apply requires a saved preview JSON file") }
            let data = try Data(contentsOf: URL(fileURLWithPath: args[0]))
            let envelope = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let plan = try JSONDecoder().decode(ExtensionPlan.self, from: envelope["result"].map { try JSONEncoder().encode($0) } ?? data)
            try runtime.applyExtensions(plan)
            try emit(["applied": true])
        case "install":
            guard args.count == 2, let profile = try runtime.state().accounts.first(where: { $0.id == args[0] }) else { throw TerminalError.invalid("extension install requires ACCOUNT_ID and EXTENSION_ID") }
            exit(try runProvider(runtime.pluginCommand(accountID: args[0], extensionID: args[1]), agent: profile.provider, runtime: runtime))
        default: throw TerminalError.invalid("Unknown extension command")
        }
    case "usage-hook":
        guard args.isEmpty else { throw TerminalError.invalid("usage-hook takes input on stdin") }
        let data = try boundedHookInput()
        if let pane = ProcessInfo.processInfo.environment["TRANO_SESSION"], let generation = ProcessInfo.processInfo.environment["TRANO_LAUNCH_ID"] {
            try runtime.recordUsageHook(paneID: pane, generation: generation, data: data, originPID: getpid())
        }
    case "hook":
        guard (1...2).contains(args.count), let agent = AgentKind(rawValue: args[0]) else { throw TerminalError.invalid("hook requires provider") }
        let data = try boundedHookInput()
        if let id = ProcessInfo.processInfo.environment["TRANO_SESSION"], let generation = ProcessInfo.processInfo.environment["TRANO_LAUNCH_ID"], !generation.isEmpty {
            try runtime.recordAgentHook(paneID: id, generation: generation, provider: agent, data: data, originPID: getpid())
        }
    case "account":
        guard !args.isEmpty else { throw TerminalError.invalid("account requires list, add or exec") }
        switch args.removeFirst() {
        case "list": try emit(runtime.state().accounts)
        case "usage":
            if args.isEmpty { try emit(runtime.accountUsage()) }
            else { guard args.count == 1 else { throw TerminalError.invalid("account usage accepts one ID") }; try emit(runtime.refreshAccountUsage(accountID: args[0])) }
        case "switch":
            guard args.count == 2 else { throw TerminalError.invalid("account switch requires PANE_ID ACCOUNT_ID") }
            try emit(runtime.requestAccountSwitch(paneID: args[0], targetAccountID: args[1]))
        case "switching":
            guard args.count == 1, ["on", "off"].contains(args[0]) else { throw TerminalError.invalid("account switching requires on or off") }
            try runtime.update { $0.settings.automaticAccountSwitching = args[0] == "on" }
            try emit(["enabled": args[0] == "on"])
        case "add":
            let provider = option("--provider") ?? "", label = option("--label") ?? ""
            guard args.isEmpty, let provider = AgentKind(rawValue: provider) else { throw TerminalError.invalid("account add requires --provider and --label") }
            try emit(runtime.addAccount(provider: provider, label: label))
        case "exec":
            guard !args.isEmpty else { throw TerminalError.invalid("account exec requires ID") }
            let id = args.removeFirst()
            let login = args.first == "--login"
            if login { args.removeFirst() }
            if args.first == "--" { args.removeFirst() }
            guard let profile = try runtime.state().accounts.first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown account") }
            exit(try runProvider(runtime.accountCommand(id, login: login, arguments: args), agent: profile.provider, runtime: runtime, accountID: id))
        default: throw TerminalError.invalid("Unknown account command")
        }
    case "actions": try emit(ActionCatalog.resolved(overrides: runtime.state().settings.keyBindings))
    case "workspaces":
        let query = option("--query") ?? ""
        guard args.isEmpty else { throw TerminalError.invalid("Unexpected workspaces arguments") }
        try emit(runtime.state().layout.workspaces.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) })
    case "do":
        let workspace = option("--workspace"), tab = option("--tab"), pane = option("--pane"), cwd = option("--cwd")
        guard args.count == 1, let action = ActionID(rawValue: args[0]) else { throw TerminalError.invalid("do requires an action ID from actions") }
        try runtime.performAction(action, cwd: cwd, workspaceID: workspace, tabID: tab, paneID: pane, requestNavigation: true)
        try emit(runtime.state().layout)
    case "select":
        guard args.count == 1 else { throw TerminalError.invalid("select requires a workspace ID") }
        try runtime.update { state in
            try state.layout.selectWorkspace(args[0])
            state.navigationRequest = NavigationRequest(workspaceID: args[0])
        }
        try emit(["selected": args[0]])
    case "launch":
        let cwd = option("--cwd") ?? FileManager.default.currentDirectoryPath
        let agentText = option("--agent") ?? "shell"
        let prompt = option("--prompt") ?? ""
        guard args.isEmpty, let agent = AgentKind(rawValue: agentText) else { throw TerminalError.invalid("launch requires shell, claude or codex") }
        try emit(runtime.launch(cwd: cwd, agent: agent, prompt: prompt))
    case "monitor":
        guard args.count == 1, UUID(uuidString: args[0]) != nil else { throw TerminalError.invalid("monitor requires ID") }
        try monitorPane(args[0], runtime: runtime)
    case "scrollback":
        guard !args.isEmpty else { throw TerminalError.invalid("scrollback requires list, save or replay") }
        switch args.removeFirst() {
        case "list": try emit(runtime.scrollbackMetadata())
        case "save":
            guard args.count == 1 else { throw TerminalError.invalid("scrollback save requires a pane ID") }
            try runtime.snapshotScrollback(args[0]); try emit(["saved": true])
        case "replay":
            guard args.count == 1, ProcessInfo.processInfo.environment["TRANO_SESSION"] == args[0] else { throw TerminalError.invalid("Scrollback replay must run inside its own pane") }
            let text = try runtime.replayScrollback(args[0])
            if !text.isEmpty { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        default: throw TerminalError.invalid("Unknown scrollback command")
        }
    case "run":
        let name = option("--agent") ?? ""
        guard let agent = AgentKind(rawValue: name), agent != .shell,
              ProcessInfo.processInfo.environment["TRANO_SESSION"] != nil else { throw TerminalError.invalid("run requires --agent claude|codex inside a Trano session") }
        if args.first == "--" { args.removeFirst() }
        exit(try runProvider(AccountCommand(arguments: [name] + args, environment: [:], removeEnvironment: []), agent: agent, runtime: runtime))
    case "serve":
        let service = APIService(runtime: runtime)
        try service.start()
        try emit(["listening": service.path])
        withExtendedLifetime(service) { dispatchMain() }
    case "api":
        guard (1...2).contains(args.count) else { throw TerminalError.invalid("api requires METHOD [PARAMS_JSON]") }
        let params = args.count == 2 ? try JSONDecoder().decode([String: JSONValue].self, from: Data(args[1].utf8)) : [:]
        let response = try APIClient(path: runtime.root.appendingPathComponent("api.sock").path).call(APIRequest(method: args[0], params: params))
        let encoder = JSONEncoder()
        FileHandle.standardOutput.write(try encoder.encode(response))
        FileHandle.standardOutput.write(Data([10]))
        if response.error != nil { exit(1) }
    case "check":
        try emit(["tmux": runtime.executable, "socket": runtime.socketPath, "version": "0.1.0-dev"])
    case "list":
        let query = option("--query") ?? ""
        let sessions = try runtime.list().filter { query.isEmpty || ($0.title + " " + $0.cwd + " " + $0.id).localizedCaseInsensitiveContains(query) }
        try emit(sessions)
    case "create":
        let title = option("--title") ?? "Terminal"
        let cwd = option("--cwd") ?? FileManager.default.currentDirectoryPath
        guard args.isEmpty else { throw TerminalError.invalid("Unexpected create arguments") }
        try emit(runtime.create(title: title, cwd: cwd))
    case "state": try emit(runtime.state())
    case "capture":
        let linesText = option("--lines") ?? "100"
        guard args.count == 1, let lines = Int(linesText) else { throw TerminalError.invalid("capture requires ID and integer --lines") }
        try emit(["text": runtime.capture(args[0], lines: lines)])
    case "send":
        let enter = args.count == 3 && args.last == "--enter"
        if enter { args.removeLast() }
        guard args.count == 2 else { throw TerminalError.invalid("send requires ID and one TEXT argument") }
        try runtime.send(args[0], text: args[1], enter: enter)
        try emit(["sent": true])
    case "terminate":
        guard args.count == 1 else { throw TerminalError.invalid("terminate requires ID") }
        try runtime.terminate(args[0])
        try emit(["terminated": true])
    case "detach":
        guard args.count == 1, try runtime.list().contains(where: { $0.id == args[0] }) else { throw TerminalError.invalid("Unknown session") }
        try runtime.update { $0.layout.detach(args[0]) }
        try emit(["detached": true])
    case "attach":
        guard args.count == 1 else { throw TerminalError.invalid("attach requires ID") }
        try runtime.update { state in
            guard state.sessions.contains(where: { $0.id == args[0] }) else { throw TerminalError.invalid("Unknown session") }
            if state.layout.tabs.contains(where: { $0.panes.contains(args[0]) }) {
                try state.layout.focusPane(args[0])
            } else { state.layout.addTab(paneID: args[0]) }
            if let workspace = state.layout.selectedWorkspaceID { state.navigationRequest = NavigationRequest(workspaceID: workspace, paneID: args[0]) }
        }
        try emit(["attached": true])
    case "status":
        let reason = option("--reason") ?? ""
        let agentText = option("--agent") ?? "shell"
        guard args.count == 2, let state = ActivityState(rawValue: args[1]), let agent = AgentKind(rawValue: agentText) else {
            throw TerminalError.invalid("status requires ID, valid STATE and --agent")
        }
        try runtime.report(args[0], state: state, reason: reason, agent: agent)
        try emit(["reported": true])
    default: throw TerminalError.invalid("Unknown command: \(command)")
    }
} catch {
    let data = try? JSONSerialization.data(withJSONObject: ["apiVersion": 1, "error": error.localizedDescription], options: [.sortedKeys])
    FileHandle.standardError.write(data ?? Data("{\"error\":\"encoding failed\"}".utf8))
    FileHandle.standardError.write(Data([10]))
    exit(1)
}
