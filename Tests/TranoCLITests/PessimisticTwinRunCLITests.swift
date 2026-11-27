import Foundation
import XCTest
import TerminalCore
@testable import TranoCLI

final class PessimisticTwinRunCLITests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-10
    private let runID = "22222222-2222-4222-8222-222222222222"
    func testOwnedRunParsesOnlyExplicitUUIDAndRoundWithoutFallback() throws {
        XCTAssertEqual(try TwinRunCLI.parse(["run", runID, "--round", "2"]), .init(runID: runID, round: 2))
        for arguments in [[], ["run", runID], ["run", "bad", "--round", "1"], ["report", runID, "--round", "1"], ["run", runID, "--round", "0"], ["run", runID, "--round", "9"], ["run", runID, "--round", "1", "--agent", "claude"], ["run", runID, "--round", "1", "--round", "2"]] {
            XCTAssertThrowsError(try TwinRunCLI.parse(arguments))
        }
    }
    func testDirectProviderCommandPreservesExactArgumentsAndPrivateIdentity() {
        let args = ["fork", "exact-conversation", "-C", "/검토 경로", "quote ' $value\n끝"]
        let command = TwinRunCLI.command(executable: "/provider path/codex", arguments: args, environment: ["CODEX_HOME": "/private/profile"], removeEnvironment: ["OPENAI_API_KEY"])
        XCTAssertEqual(command.executable, "/provider path/codex"); XCTAssertEqual(command.arguments, args)
        XCTAssertEqual(command.environment, ["CODEX_HOME": "/private/profile"]); XCTAssertEqual(command.removeEnvironment, ["OPENAI_API_KEY"])
    }
    func testTwinEnvironmentRemovesSourceBindingsAndRoutesOnlyOwnedScopedHelpers() {
        let base = ["CLAUDE_CONFIG_DIR": "/source/profile", "TRANO_LAUNCH_ID": "original-generation", "TRANO_SESSION": "original-pane", "REX_BLOCK": "old", "TRANO_API_SOCKET": "/global.sock", "EASYDECISION_ADAPTER_BIN": "/user/adapter", "EASYDECISION_SOCKET": "/global-decision.sock", "PATH": "/usr/bin:/bin"]
        let command = TwinRunCLI.command(executable: "/bin/claude", arguments: [], environment: ["CLAUDE_CONFIG_DIR": "/private/profile"], removeEnvironment: ["CLAUDE_CONFIG_DIR", "TRANO_API_SOCKET"])
        let env = TwinRunCLI.environment(base, command: command, paneID: "twin-pane", generation: "new-generation", helper: "/signed/Trano CLI", socket: "/owned/twin.sock")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/private/profile"); XCTAssertEqual(env["TRANO_SESSION"], "twin-pane")
        XCTAssertEqual(env["TRANO_LAUNCH_ID"], "new-generation"); XCTAssertEqual(env["TRANO_CLI_PATH"], "/signed/Trano CLI")
        XCTAssertEqual(env["TRANO_TWIN_API_SOCKET"], "/owned/twin.sock"); XCTAssertEqual(env["EASYDECISION_SOCKET"], "/owned/twin.sock")
        XCTAssertNil(env["REX_BLOCK"]); XCTAssertNil(env["TRANO_API_SOCKET"]); XCTAssertNil(env["EASYDECISION_ADAPTER_BIN"])
        XCTAssertEqual(base["TRANO_SESSION"], "original-pane")
    }
    func testSuspendedChildCannotContinueBeforeBothBindingsAndTerminalOwnership() throws {
        var order: [String] = []
        try TwinRunCLI.activateSuspendedProvider(record: { order.append("record-process") }, register: { order.append("register-owned-prompt") }, giveTerminal: { order.append("give-terminal") }, resume: { order.append("SIGCONT") })
        XCTAssertEqual(order, ["record-process", "register-owned-prompt", "give-terminal", "SIGCONT"])
    }
    func testAdmissionFailureNeverContinuesSuspendedProvider() {
        for failure in 0..<3 {
            var order: [Int] = []
            func step(_ index: Int) throws { order.append(index); if index == failure { throw TerminalError.invalid("stale owned binding") } }
            XCTAssertThrowsError(try TwinRunCLI.activateSuspendedProvider(record: { try step(0) }, register: { try step(1) }, giveTerminal: { try step(2) }, resume: { XCTFail("Unregistered provider continued") }))
            XCTAssertEqual(order, Array(0...failure))
        }
    }
    func testExitReceiptPrecedesLifecycleEndAndFailurePreservesUncertainLaunch() throws {
        var order: [String] = []
        try TwinRunCLI.finish(recordExit: { order.append("receipt") }, endLaunch: { order.append("end") })
        XCTAssertEqual(order, ["receipt", "end"])
        XCTAssertThrowsError(try TwinRunCLI.finish(recordExit: { throw TerminalError.runtime("receipt unavailable") }, endLaunch: { XCTFail("Uncertain receipt cannot end launch") }))
    }

    func testInheritedEnvironmentKeepsTerminalLocaleAndDropsUnrelatedSecrets() {
        let command = TwinRunCLI.command(executable: "/bin/claude", arguments: [], environment: ["CLAUDE_CONFIG_DIR": "/private/profile", "TMPDIR": "/private/profile/tmp"], removeEnvironment: [])
        let base = ["HOME": "/own/home", "USER": "own-user", "LOGNAME": "own-user", "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Trano", "LANG": "ko_KR.UTF-8", "LC_CTYPE": "UTF-8", "TZ": "Asia/Seoul", "AWS_ACCESS_KEY_ID": "fixture-secret", "AWS_SECRET_ACCESS_KEY": "fixture-secret", "AWS_SESSION_TOKEN": "fixture-secret", "GH_TOKEN": "fixture-secret", "CUSTOM_TOKEN": "fixture-secret", "HTTP_PROXY": "http://not-inherited", "UNRELATED_CONFIG": "/source/config", "BASH_ENV": "/source/env", "SSH_AUTH_SOCK": "/source/agent.sock", "TRANO_DATA_DIR": "/source/runtime"]
        let env = TwinRunCLI.environment(base, command: command, paneID: "pane", generation: "generation", helper: "/signed/helper", socket: "/runtime/twin.sock")
        for key in ["HOME", "USER", "LOGNAME", "TERM", "COLORTERM", "TERM_PROGRAM", "LANG", "LC_CTYPE", "TZ"] { XCTAssertEqual(env[key], base[key], key) }
        for key in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "GH_TOKEN", "CUSTOM_TOKEN", "HTTP_PROXY", "UNRELATED_CONFIG", "BASH_ENV", "SSH_AUTH_SOCK", "TRANO_DATA_DIR"] { XCTAssertNil(env[key], key) }
        XCTAssertEqual(env["TMPDIR"], "/private/profile/tmp")
    }
    func testManagedGitPathAndDirectoryOrExecutableAliasesAreRemoved() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-path-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = base.appendingPathComponent("runtime"), ordinary = base.appendingPathComponent("ordinary"), linkedExecutable = base.appendingPathComponent("executable-alias")
        for path in [runtime, ordinary, linkedExecutable, runtime.appendingPathComponent("bin"), runtime.appendingPathComponent("git-bin"), runtime.appendingPathComponent("shell"), runtime.appendingPathComponent("shell/bin")] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let shim = runtime.appendingPathComponent("git-bin/git"); try Data("fixture shim".utf8).write(to: shim)
        let alias = base.appendingPathComponent("directory-alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: runtime.appendingPathComponent("git-bin"))
        try FileManager.default.createSymbolicLink(at: linkedExecutable.appendingPathComponent("git"), withDestinationURL: shim)
        let paths = [runtime.appendingPathComponent("bin").path, runtime.appendingPathComponent("git-bin").path, runtime.appendingPathComponent("shell/bin").path, alias.path, linkedExecutable.path, ordinary.path, "/usr/bin", "/bin", ".", "relative"]
        let command = TwinRunCLI.command(executable: "/bin/codex", arguments: [], environment: [:], removeEnvironment: [])
        let env = TwinRunCLI.environment(["PATH": paths.joined(separator: ":")], command: command, paneID: "pane", generation: "generation", helper: "/signed/helper", socket: runtime.appendingPathComponent("twin.sock").path)
        XCTAssertEqual(env["PATH"]?.split(separator: ":").map(String.init), [ordinary.path, "/usr/bin", "/bin"])
    }

    func testFiniteAuthenticationExpirySignalsOnlyOnceThenUsesMonotonicKillDeadline() {
        let cutoff = Date(timeIntervalSince1970: 1_900_000_000)
        var guardState = TwinRunCLI.ExpiryGuard(expiresAt: cutoff)
        XCTAssertNil(guardState.poll(now: cutoff.addingTimeInterval(-1), uptime: 100))
        XCTAssertEqual(guardState.poll(now: cutoff, uptime: 101), SIGINT)
        XCTAssertNil(guardState.poll(now: cutoff.addingTimeInterval(60), uptime: 105.9))
        XCTAssertEqual(guardState.poll(now: cutoff.addingTimeInterval(-600), uptime: 106), SIGKILL)
        XCTAssertNil(guardState.poll(now: cutoff.addingTimeInterval(600), uptime: 120))
        XCTAssertEqual(guardState.exitCode(0, now: cutoff.addingTimeInterval(-600)), 78)
    }
    func testAuthenticationExpiryCannotTurnSuccessfulExitIntoAccountFallback() {
        let cutoff = Date(timeIntervalSince1970: 1_900_000_000)
        let guardState = TwinRunCLI.ExpiryGuard(expiresAt: cutoff)
        XCTAssertEqual(guardState.exitCode(0, now: cutoff.addingTimeInterval(-1)), 0)
        XCTAssertEqual(guardState.exitCode(7, now: cutoff.addingTimeInterval(-1)), 7)
        XCTAssertEqual(guardState.exitCode(0, now: cutoff), 78)
    }

}
