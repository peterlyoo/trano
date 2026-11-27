import Foundation

extension TerminalRuntime {
    public func conversationHistorySources(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [ConversationHistorySource] {
        ConversationHistorySources.build(state: try state(), runtimeRoot: root, home: home, environment: environment)
    }

    public func conversationResumeContext() throws -> ConversationResumeContext {
        let state = try state()
        let sessions = try list()
        _ = try detachedPaneReservations().reservedPaneIDs()
        let unisessionPaneID = try unisessionBinding()?.paneID
        let supervisorPaneID: String?
        switch SupervisorStateStore(root: root).reservation() {
        case .absent: supervisorPaneID = nil
        case .bound(let pane): supervisorPaneID = pane
        case .unavailable: throw TerminalError.invalid("Supervisor ownership is unavailable. Reopen Resume after its state is repaired.")
        }
        return ConversationResumeContext(state: state, sessions: sessions,
            sources: ConversationHistorySources.build(state: state, runtimeRoot: root, home: FileManager.default.homeDirectoryForCurrentUser,
                                                       environment: ProcessInfo.processInfo.environment),
            supervisorPaneID: supervisorPaneID, unisessionPaneID: unisessionPaneID)
    }

    public func resumeConversation(_ conversation: AgentConversation, workspaceID: String?,
                                   isCancelled: @escaping () -> Bool = { false }) throws -> ConversationResumeOutcome {
        guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else {
            throw TerminalError.invalid("The bundled Trano helper is unavailable")
        }
        let organizationAuthorization: AccountOrganizationAuthorization?
        if let accountID = conversation.source.accountID,
           ConversationResumeCoordinator.livePane(for: conversation, context: try conversationResumeContext()) == nil {
            organizationAuthorization = try preflightAccountOrganization(accountID: accountID, cwd: conversation.cwd)
        } else { organizationAuthorization = nil }
        return try transaction {
            let operations = ConversationResumeOperations(context: { try self.conversationResumeContext() },
                validate: { entry in
                    if let account = entry.source.accountID {
                        guard try self.accountRoot(account).standardizedFileURL.path == entry.source.configurationRoot else {
                            throw TerminalError.invalid("The original account storage changed")
                        }
                    }
                    let fresh = try ConversationHistoryIndex.validate(conversation: entry)
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: fresh.cwd, isDirectory: &directory), directory.boolValue else {
                        throw TerminalError.invalid("The original project folder is unavailable")
                    }
                    return fresh
                }, create: { entry in
                    if let accountID = entry.source.accountID {
                        guard let organizationAuthorization, organizationAuthorization.accountID == accountID else {
                            throw TerminalError.invalid("Account organization changed. Reopen Resume.")
                        }
                        try self.validateAccountOrganizationAuthorization(organizationAuthorization, cwd: entry.cwd)
                    }
                    return try self.create(title: String(entry.title.prefix(200)), cwd: entry.cwd, shell: "/bin/zsh", arguments: ["-l"])
                }, stage: { entry, pane, workspace in
                    let boot = try Self.bootIdentity()
                    var binding: AgentLaunch?
                    try self.update { state in
                        binding = try ConversationResumeCoordinator.stage(entry, pane: pane, workspaceID: workspace, bootID: boot, state: &state)
                    }
                    return binding!
                }, launch: { pane, launch in
                    let command = try ConversationResumeCoordinator.command(helper: helperExecutable, pane: pane, launch: launch)
                    try self.send(pane.id, text: command, enter: true)
                }, open: { paneID in
                    try self.update { state in
                        if !state.layout.tabs.contains(where: { $0.panes.contains(paneID) }),
                           let index = state.layout.closedTabs.lastIndex(where: { $0.panes.contains(paneID) }) {
                            let snapshot = state.layout.closedTabs.remove(at: index)
                            state.layout.closedTabs.append(snapshot)
                            state.layout.restoreTab()
                        }
                        if !state.layout.tabs.contains(where: { $0.panes.contains(paneID) }) { state.layout.addTab(paneID: paneID) }
                        try state.layout.focusPane(paneID)
                    }
                }, rollback: { paneID in
                    try? self.terminate(paneID)
                    try? self.update { state in state.agentLaunches.removeAll { $0.paneID == paneID } }
                }, isCancelled: isCancelled)
            return try ConversationResumeCoordinator.resume(conversation, workspaceID: workspaceID, operations: operations)
        }
    }
}
