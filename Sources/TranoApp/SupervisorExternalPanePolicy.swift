import TerminalCore

struct SupervisorExternalPanePolicy {
    let binding: SupervisorBinding

    init(binding: SupervisorBinding) { self.binding = binding }

    var retainedPaneIDs: Set<String> { [binding.paneID] }
    var allowsWorkspaceOwnership: Bool { false }

    func sessions(_ values: [TerminalSession]) -> [TerminalSession] {
        values.filter {
            $0.id == binding.paneID && $0.pid == binding.backendPID && $0.remote == nil && $0.host == "local"
        }
    }

    func project(_ snapshot: RuntimeState) -> RuntimeState {
        var projected = snapshot
        projected.layout = WorkspaceLayout()
        projected.navigationRequest = nil
        projected.sessions = sessions(snapshot.sessions)
        return projected
    }
}
