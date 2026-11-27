import Foundation
import XCTest
@testable import TerminalCore

final class TerminalLaunchSelectionTests: XCTestCase {
    private var preferences: TerminalPreferences {
        var value = TerminalPreferences()
        value.startupCommand = TerminalStartupCommand(executable: "/usr/bin/env",
                                                      arguments: ["커맨드", "space name", "'quote'", "tail;"])
        return value
    }

    // Implements: FR-SET-97
    func testOnlyNewImplicitLocalShellUsesConfiguredStartup() throws {
        XCTAssertEqual(try TerminalLaunchSelection.resolve(preferences: preferences), preferences.startupCommand)
        let restored = try TerminalLaunchSelection.resolve(preferences: preferences,
                                                            restoringID: UUID().uuidString)
        XCTAssertEqual(restored, TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"]))
        XCTAssertEqual(try TerminalLaunchSelection.resolve(preferences: TerminalPreferences()), restored)
    }

    // Implements: FR-SET-97
    func testExplicitRemoteManagedAndArgvRemainExact() throws {
        let argv = ["-t", "호스트", "codex", "resume", "id;", "NFD-e\u{301}", "space value"]
        let remote = try TerminalLaunchSelection.resolve(preferences: preferences, shell: "/usr/bin/ssh",
                                                          arguments: argv)
        XCTAssertEqual(remote.executable, "/usr/bin/ssh")
        XCTAssertEqual(remote.arguments.map { Array($0.utf8) }, argv.map { Array($0.utf8) })
        XCTAssertEqual(try TerminalLaunchSelection.resolve(preferences: preferences, arguments: []),
                       TerminalStartupCommand(executable: "/bin/zsh", arguments: []))
        XCTAssertNil(TerminalLaunchSelection.managedShell(for: .shell))
        for agent in [AgentKind.claude, .codex] {
            XCTAssertEqual(TerminalLaunchSelection.managedShell(for: agent),
                           TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"]))
        }
    }

    // Implements: FR-SET-97
    func testScrollbackReplayWrapperKeepsExactExecutableAndArguments() throws {
        let command = try TerminalLaunchSelection.resolve(preferences: preferences)
        let plain = TerminalLaunchSelection.argv(command, replayScrollback: false)
        XCTAssertEqual(plain, [command.executable] + command.arguments)
        let wrapped = TerminalLaunchSelection.argv(command, replayScrollback: true)
        guard wrapped.count == command.arguments.count + 5 else {
            return XCTFail("Expected fixed replay prefix plus exact executable/argv")
        }
        XCTAssertEqual(Array(wrapped.prefix(2)), ["/bin/sh", "-c"])
        XCTAssertEqual(wrapped[2], "\"$TRANO_CLI_PATH\" scrollback replay \"$TRANO_SESSION\"; exec \"$@\"")
        XCTAssertEqual(wrapped[3], "trano-restore")
        XCTAssertEqual(Array(wrapped.dropFirst(4)), plain)
    }

    // Implements: FR-SET-97
    func testInvalidSelectedArgumentsAreRejectedButRecoveryDoesNotReadUserCommand() throws {
        XCTAssertThrowsError(try TerminalLaunchSelection.resolve(preferences: preferences,
                                                                  shell: "relative", arguments: []))
        XCTAssertThrowsError(try TerminalLaunchSelection.resolve(preferences: preferences,
                                                                  shell: "/bin/zsh", arguments: ["bad\0arg"]))
        var invalid = preferences
        invalid.startupCommand = TerminalStartupCommand(executable: "relative")
        XCTAssertThrowsError(try TerminalLaunchSelection.resolve(preferences: invalid))
        XCTAssertEqual(try TerminalLaunchSelection.resolve(preferences: invalid, restoringID: "restore"),
                       TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"]))
    }
}
