import Foundation

public struct LaunchResult: Encodable {
    public let workspaceID: String
    public let tabID: String
    public let pane: TerminalSession
}

extension TerminalRuntime {
    public func launch(cwd: String, agent: AgentKind = .shell, prompt: String = "") throws -> LaunchResult {
        guard prompt.utf8.count <= 32_768, !prompt.contains("\0"), agent != .shell || prompt.isEmpty else { throw TerminalError.invalid("A prompt requires an agent and must fit in 32 KiB") }
        if agent != .shell {
            guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else { throw TerminalError.invalid("Agent launch requires the bundled trano CLI") }
        }
        return try transaction {
            let directory = URL(fileURLWithPath: cwd).standardizedFileURL.path
            let pane = try create(title: agent == .shell ? "Terminal" : agent.rawValue.capitalized, cwd: directory)
            do {
                var result: LaunchResult?
                try update { state in
                    let projectPanes = Set(state.sessions.filter { $0.cwd == directory && $0.id != pane.id }.map(\.id))
                    let existing = state.layout.tabs.first { !$0.panes.filter(projectPanes.contains).isEmpty }?.workspaceID
                    if let existing { try state.layout.selectWorkspace(existing) }
                    else { state.layout.addWorkspace(title: URL(fileURLWithPath: directory).lastPathComponent) }
                    let tab = state.layout.addTab(paneID: pane.id)
                    let workspace = state.layout.selectedWorkspaceID!
                    state.navigationRequest = NavigationRequest(workspaceID: workspace, tabID: tab, paneID: pane.id)
                    result = LaunchResult(workspaceID: workspace, tabID: tab, pane: pane)
                }
                if agent != .shell, let helperExecutable {
                    let command = [helperExecutable, "run", "--agent", agent.rawValue, "--"] + (prompt.isEmpty ? [] : [prompt])
                    try send(pane.id, text: command.map(ShellQuote.quote).joined(separator: " "), enter: true)
                }
                return result!
            } catch { try? terminate(pane.id); throw error }
        }
    }
}
