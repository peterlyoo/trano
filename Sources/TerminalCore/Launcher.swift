import Foundation

public struct LaunchResult: Encodable {
    public let workspaceID: String
    public let tabID: String
    public let pane: TerminalSession
}

struct OwnedTerminalLaunch {
    let title: String
    let workspaceID: String
    let paneID: String
    let command: (TerminalSession) throws -> [String]
    let beforeWrite: (TerminalSession) throws -> Void
}

extension TerminalRuntime {
    public func launch(cwd: String, agent: AgentKind = .shell, prompt: String = "") throws -> LaunchResult {
        try launch(cwd: cwd, agent: agent, prompt: prompt, owned: nil)
    }

    func launch(cwd: String, agent: AgentKind, prompt: String = "", owned: OwnedTerminalLaunch?) throws -> LaunchResult {
        guard prompt.utf8.count <= 32_768, !prompt.contains("\0"), agent != .shell || prompt.isEmpty else { throw TerminalError.invalid("A prompt requires an agent and must fit in 32 KiB") }
        if agent != .shell {
            guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else { throw TerminalError.invalid("Agent launch requires the bundled trano CLI") }
        }
        return try transaction {
            let directory = URL(fileURLWithPath: cwd).standardizedFileURL.path
            let bootstrap = TerminalLaunchSelection.managedShell(for: agent)
            let pane = try create(title: owned?.title ?? (agent == .shell ? "Terminal" : agent.rawValue.capitalized), cwd: directory,
                shell: owned == nil ? bootstrap?.executable : "/bin/bash",
                arguments: owned == nil ? bootstrap?.arguments : ["--noprofile", "--norc"], reservedID: owned?.paneID)
            do {
                let command = try owned?.command(pane)
                var result: LaunchResult?
                try update { state in
                    let previous = state.layout
                    if let owned { try state.layout.selectWorkspace(owned.workspaceID) }
                    else {
                        let projectPanes = Set(state.sessions.filter { $0.cwd == directory && $0.id != pane.id }.map(\.id))
                        try state.layout.selectProjectWorkspace(projectPaneIDs: projectPanes)
                    }
                    let tab = state.layout.addTab(paneID: pane.id)
                    let workspace = state.layout.selectedWorkspaceID!
                    if owned != nil {
                        if let oldTab = previous.selectedTabID, state.layout.tabs.contains(where: { $0.id == oldTab }) { try state.layout.selectTab(oldTab) }
                        else if let oldWorkspace = previous.selectedWorkspaceID { try state.layout.selectWorkspace(oldWorkspace) }
                        if let oldPane = previous.focusedPaneID { try state.layout.focusPane(oldPane) }
                    } else { state.navigationRequest = NavigationRequest(workspaceID: workspace, tabID: tab, paneID: pane.id) }
                    result = LaunchResult(workspaceID: workspace, tabID: tab, pane: pane)
                }
                if agent != .shell, let helperExecutable {
                    let invocation = command ?? [helperExecutable, "run", "--agent", agent.rawValue, "--"] + (prompt.isEmpty ? [] : [prompt])
                    try send(pane.id, text: invocation.map(ShellQuote.quote).joined(separator: " "), enter: true,
                        beforeWrite: owned.map { plan in { try plan.beforeWrite(pane) } })
                }
                return result!
            } catch { try? terminate(pane.id); throw error }
        }
    }
}
