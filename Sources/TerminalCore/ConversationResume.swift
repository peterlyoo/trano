import Foundation

public struct ConversationResumeContext {
    public let state: RuntimeState
    public let livePaneIDs: Set<String>
    public let sources: [ConversationHistorySource]
    public let supervisorPaneID: String?
    public let unisessionPaneID: String?
    public init(state: RuntimeState, livePaneIDs: Set<String>, sources: [ConversationHistorySource], supervisorPaneID: String? = nil, unisessionPaneID: String? = nil) {
        self.state = state; self.livePaneIDs = livePaneIDs; self.sources = sources; self.supervisorPaneID = supervisorPaneID; self.unisessionPaneID = unisessionPaneID
    }
    public init(state: RuntimeState, sessions: [TerminalSession], sources: [ConversationHistorySource], supervisorPaneID: String? = nil, unisessionPaneID: String? = nil) {
        self.init(state: state, livePaneIDs: Set(sessions.filter { $0.alive && $0.remote == nil }.map(\.id)),
                  sources: sources, supervisorPaneID: supervisorPaneID, unisessionPaneID: unisessionPaneID)
    }
}

public struct ConversationResumeOutcome: Equatable {
    public let paneID: String
    public let existing: Bool
    public let supervisor: Bool
    public let unisession: Bool
    public init(paneID: String, existing: Bool, supervisor: Bool = false, unisession: Bool = false) {
        self.paneID = paneID; self.existing = existing; self.supervisor = supervisor; self.unisession = unisession
    }
}

public struct ConversationResumeOperations {
    public var context: () throws -> ConversationResumeContext
    public var validate: (AgentConversation) throws -> AgentConversation
    public var create: (AgentConversation) throws -> TerminalSession
    public var stage: (AgentConversation, TerminalSession, String?) throws -> AgentLaunch
    public var launch: (TerminalSession, AgentLaunch) throws -> Void
    public var open: (String) throws -> Void
    public var rollback: (String) -> Void
    public var isCancelled: () -> Bool = { false }
}

public enum ConversationResumeCoordinator {
    public static func sameSource(_ lhs: ConversationHistorySource, _ rhs: ConversationHistorySource) -> Bool {
        lhs.id == rhs.id && lhs.provider == rhs.provider && lhs.accountID == rhs.accountID
            && lhs.configurationRoot == rhs.configurationRoot
    }

    public static func livePane(for entry: AgentConversation, context: ConversationResumeContext) -> String? {
        context.state.agentLaunches.first { launch in
            launch.provider == entry.source.provider && launch.providerSessionID?.lowercased() == entry.providerSessionID.lowercased()
                && launch.configurationRoot == entry.source.configurationRoot && launch.accountID == entry.source.accountID
                && launch.lifecycle == .active && context.livePaneIDs.contains(launch.paneID)
                && context.state.sessions.contains { $0.id == launch.paneID && $0.remote == nil }
        }?.paneID
    }

    public static func resume(_ conversation: AgentConversation, workspaceID: String?, operations: ConversationResumeOperations) throws -> ConversationResumeOutcome {
        func requireActive() throws {
            if operations.isCancelled() { throw TerminalError.invalid("Resume was cancelled") }
        }
        try requireActive()
        let context = try operations.context()
        guard let currentSource = context.sources.first(where: { sameSource($0, conversation.source) }) else {
            throw TerminalError.invalid("The conversation account or storage location changed. Refresh the list.")
        }
        let fresh = try operations.validate(conversation)
        guard sameSource(fresh.source, conversation.source), fresh.providerSessionID == conversation.providerSessionID,
              fresh.cwd == conversation.cwd, fresh.relativePath == conversation.relativePath,
              UUID(uuidString: fresh.providerSessionID) != nil, fresh.source.provider != .shell,
              fresh.cwd.hasPrefix("/"), !fresh.cwd.contains("\0"), !fresh.cwd.contains("\n") else {
            throw TerminalError.invalid("Conversation identity or original directory changed. Refresh the list.")
        }
        try requireActive()
        if let shared = context.unisessionPaneID, context.livePaneIDs.contains(shared),
           context.state.sessions.contains(where: { $0.id == shared && $0.remote == nil }),
           context.state.agentLaunches.contains(where: { launch in
               launch.paneID == shared && launch.lifecycle == .active && launch.provider == fresh.source.provider
                   && launch.providerSessionID?.lowercased() == fresh.providerSessionID.lowercased()
                   && launch.configurationRoot == fresh.source.configurationRoot && launch.accountID == fresh.source.accountID
           }) {
            return ConversationResumeOutcome(paneID: shared, existing: true, unisession: true)
        }
        if let reserved = context.supervisorPaneID, reserved != context.unisessionPaneID,
           context.state.agentLaunches.contains(where: { launch in
               launch.paneID == reserved && launch.provider == fresh.source.provider
                   && launch.providerSessionID?.lowercased() == fresh.providerSessionID.lowercased()
                   && launch.configurationRoot == fresh.source.configurationRoot && launch.accountID == fresh.source.accountID
           }) {
            return ConversationResumeOutcome(paneID: reserved, existing: true, supervisor: true)
        }
        if let paneID = livePane(for: fresh, context: context) {
            let supervisor = paneID == context.supervisorPaneID
            if !supervisor { try operations.open(paneID) }
            return ConversationResumeOutcome(paneID: paneID, existing: true, supervisor: supervisor)
        }
        guard currentSource.enabled else { throw TerminalError.invalid("Enable this account before resuming its conversation.") }
        if let accountID = currentSource.accountID {
            guard context.state.accounts.contains(where: { $0.id == accountID && $0.provider == currentSource.provider && $0.enabled }) else {
                throw TerminalError.invalid("The original account is unavailable. Refresh the list.")
            }
        }
        if let workspaceID {
            guard context.state.layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }) else {
                throw TerminalError.invalid("The destination workspace closed. Reopen Resume from an active workspace.")
            }
        }
        let pane = try operations.create(fresh)
        guard !context.state.sessions.contains(where: { $0.id == pane.id }) else {
            throw TerminalError.invalid("Resume requires a new terminal identity")
        }
        do {
            try requireActive()
            let launch = try operations.stage(fresh, pane, workspaceID)
            try requireActive()
            try operations.launch(pane, launch)
            return ConversationResumeOutcome(paneID: pane.id, existing: false)
        } catch {
            operations.rollback(pane.id)
            throw error
        }
    }

    public static func stage(_ conversation: AgentConversation, pane: TerminalSession, workspaceID: String?, bootID: String,
                             state: inout RuntimeState) throws -> AgentLaunch {
        guard state.sessions.contains(where: { $0.id == pane.id && $0.pid == pane.pid && $0.remote == nil }),
              UUID(uuidString: conversation.providerSessionID) != nil, conversation.source.provider != .shell else {
            throw TerminalError.invalid("The new terminal or conversation identity changed")
        }
        if let workspaceID {
            guard state.layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }) else { throw TerminalError.invalid("The destination workspace closed") }
            try state.layout.selectWorkspace(workspaceID)
        } else {
            state.layout.addWorkspace(title: state.layout.randomWorkspaceTitle())
        }
        _ = state.layout.addTab(paneID: pane.id)
        let launch = AgentLaunch(paneID: pane.id, provider: conversation.source.provider,
            providerSessionID: conversation.providerSessionID, cwd: conversation.cwd, accountID: conversation.source.accountID,
            configurationRoot: conversation.source.configurationRoot,
            organizationBindingID: state.accounts.first(where: { $0.id == conversation.source.accountID })?.organizationUsageBindingID,
            bootID: bootID, processID: nil)
        state.agentLaunches.removeAll { $0.paneID == pane.id }
        state.agentLaunches.append(launch)
        return launch
    }

    public static func command(helper: String, pane: TerminalSession, launch: AgentLaunch) throws -> String {
        guard helper.hasPrefix("/"), !helper.contains("\0"), !helper.contains("\n"), !helper.contains("\r"),
              pane.id == launch.paneID, UUID(uuidString: pane.id) != nil, UUID(uuidString: launch.id) != nil else {
            throw TerminalError.invalid("Invalid conversation resume command")
        }
        let command = [helper, "recovery", "resume", pane.id, launch.id].map(ShellQuote.quote).joined(separator: " ")
        guard command.utf8.count < 1000 else { throw TerminalError.invalid("The helper path is too long for safe terminal startup") }
        return command
    }
}
