import TerminalCore

enum ExternalTerminalPanePolicy {
    case supervisor(SupervisorBinding)
    case unisession(UnisessionBinding)

    var paneID: String {
        switch self { case .supervisor(let value): return value.paneID; case .unisession(let value): return value.paneID }
    }
    var backendPID: Int32 {
        switch self { case .supervisor(let value): return value.backendPID; case .unisession(let value): return value.backendPID }
    }
    var retainedPaneIDs: Set<String> { [paneID] }
    func sessions(_ values: [TerminalSession]) -> [TerminalSession] {
        values.filter { $0.id == paneID && $0.pid == backendPID && $0.remote == nil && $0.host == "local" }
    }
    func applyLocalFontSize(_ size: Double, settings: inout TerminalSettings, preferences: inout TerminalPreferences) {
        preferences.fontSize = size; settings.fontSize = size
        if let id = settings.paneAppearanceProfiles[paneID], let index = settings.appearanceProfiles.firstIndex(where: { $0.id == id }) {
            settings.appearanceProfiles[index].fontSize = size
        }
    }
    func project(_ snapshot: RuntimeState) -> RuntimeState {
        var projected = snapshot
        projected.layout = WorkspaceLayout(); projected.navigationRequest = nil
        projected.sessions = sessions(snapshot.sessions)
        return projected
    }
}

internal enum UnisessionLaunchDirectory {
    static func resolve(_ pane: TerminalSession?, home: String) -> String {
        guard let pane, pane.remote == nil else { return home }
        return pane.cwd
    }
}
