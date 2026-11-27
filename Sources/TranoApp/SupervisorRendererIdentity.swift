import TerminalCore

enum SupervisorRendererIdentity {
    static func validate(binding: SupervisorBinding, currentBinding: SupervisorBinding?, sessions: [TerminalSession],
                         readBackendIdentity: (Int32) -> SupervisorProcessIdentity?) throws {
        guard currentBinding == binding, binding.stoppedAt == nil,
              let expected = binding.processIdentity, expected.pid == binding.backendPID,
              SupervisorExternalPanePolicy(binding: binding).sessions(sessions).contains(where: { $0.alive }) else {
            throw TerminalError.invalid("Supervisor identity no longer matches its recorded session.")
        }
        guard let fresh = readBackendIdentity(binding.backendPID), fresh == expected else {
            throw TerminalError.invalid("The Supervisor process identity changed or is no longer available.")
        }
    }
}
