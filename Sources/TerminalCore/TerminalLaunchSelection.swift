import Foundation

public enum TerminalLaunchSelection {
    public static func resolve(preferences: TerminalPreferences, shell: String? = nil,
                               arguments: [String]? = nil, restoringID: String? = nil) throws -> TerminalStartupCommand {
        let command: TerminalStartupCommand
        if shell != nil || arguments != nil {
            command = TerminalStartupCommand(executable: shell ?? "/bin/zsh", arguments: arguments ?? ["-l"])
        } else if restoringID != nil {
            command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
        } else {
            command = preferences.startup()
        }
        var selected = TerminalPreferences()
        selected.startupCommand = command
        try selected.validate()
        return command
    }
    public static func managedShell(for agent: AgentKind) -> TerminalStartupCommand? {
        agent == .shell ? nil : TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
    }
    public static func argv(_ command: TerminalStartupCommand, replayScrollback: Bool) -> [String] {
        let argv = [command.executable] + command.arguments
        return replayScrollback
            ? ["/bin/sh", "-c", "\"$TRANO_CLI_PATH\" scrollback replay \"$TRANO_SESSION\"; exec \"$@\"", "trano-restore"] + argv
            : argv
    }
}
