import Darwin
import XCTest
@testable import TerminalCore

final class ForegroundProgramTests: XCTestCase {
    // Implements: FR-NAV-11
    func testKnownProgramsRequireAnExactExecutableName() {
        for (path, expected) in [("/bin/zsh", TerminalProgram.zsh), ("/tmp/k9s", .k9s), ("/usr/local/bin/claude", .claude), ("/tmp/codex", .codex)] {
            XCTAssertEqual(TerminalProgram.classify(executable: path, arguments: [path]), expected)
        }
        for path in ["/tmp/not-k9s", "/tmp/k9s-backup", "/tmp/kubectl-wrapper", "/bin/bash"] {
            XCTAssertNil(TerminalProgram.classify(executable: path, arguments: [path, "exec"]))
        }
        XCTAssertEqual(AgentKind.allCases.map(\.rawValue), ["shell", "claude", "codex"])
    }

    // Implements: FR-NAV-11
    func testKubectlExecIsTheActualSubcommandAfterGlobalOptions() {
        let valid = [
            ["kubectl", "exec", "pod", "--", "sh"],
            ["kubectl", "--context", "test", "-n", "test", "exec", "-it", "pod", "--", "bash"],
            ["kubectl", "--context", "", "exec", "pod", "--", "sh"],
            ["kubectl", "--context", "-fixture", "exec", "pod", "--", "sh"],
            ["kubectl", "--context=exec", "--namespace=test", "exec", "pod", "--", "get"],
            ["kubectl", "-nexec", "-v9", "exec", "pod", "--", "sh"],
            ["kubectl", "--as", "exec", "--as-group", "exec", "exec", "pod", "--", "sh"],
            ["kubectl", "--insecure-skip-tls-verify", "exec", "pod", "--", "sh"]
        ]
        for arguments in valid {
            XCTAssertEqual(TerminalProgram.classify(executable: "/tmp/kubectl", arguments: arguments), .kubernetesExec, arguments.joined(separator: " "))
        }
        let invalid = [
            ["kubectl", "get", "pods"], ["kubectl", "--context", "exec", "get", "pods"],
            ["kubectl", "-n", "exec", "get", "pods"], ["kubectl", "--context=exec", "get", "pods"],
            ["kubectl", "get", "pods", "--", "exec"], ["kubectl", "--", "exec"],
            ["kubectl", "--unknown-option", "exec"], ["kubectl", "--context"],
            ["kubectl", "--namespace=exec", "get", "pods"], ["kubectl"]
        ]
        for arguments in invalid {
            XCTAssertNil(TerminalProgram.classify(executable: "/tmp/kubectl", arguments: arguments), arguments.joined(separator: " "))
        }
    }

    // Implements: FR-NAV-11
    func testOptionalProgramMetadataDoesNotChangeAgentIdentityOrBreakLegacyDecoding() throws {
        let legacy = Data("{\"id\":\"pane\",\"title\":\"Stored\",\"cwd\":\"/tmp\",\"pid\":1,\"host\":\"local\",\"agent\":\"claude\",\"activity\":{\"state\":\"unknown\",\"reason\":\"\",\"source\":\"unknown\",\"updatedAt\":0},\"createdAt\":0,\"alive\":true}".utf8)
        var session = try JSONDecoder().decode(TerminalSession.self, from: legacy)
        XCTAssertNil(session.foregroundProgram)
        XCTAssertEqual(session.displayProgram, .claude)
        session.foregroundProgram = .k9s
        XCTAssertEqual(session.displayProgram, .k9s)
        XCTAssertEqual(session.agent, .claude)
        let roundTrip = try JSONDecoder().decode(TerminalSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(roundTrip.foregroundProgram, .k9s)
        for value in ["\"future-program\"", "123", "{}"] {
            XCTAssertNoThrow(try JSONDecoder().decode(TerminalProgram.self, from: Data(value.utf8)))
        }
    }

    // Implements: FR-NAV-11
    func testKernelArgumentDecoderStopsBeforeEnvironmentAndRejectsMalformedOrOversizedInput() {
        let argv = ["kubectl", "--context", "exec", "exec", "pod", "--", "sh"]
        let payload = kernelArguments(argv, environment: ["SECRET_SENTINEL=must-not-be-returned"])
        XCTAssertEqual(ForegroundProgramProbe.decodeArguments(payload), argv)
        XCTAssertNil(ForegroundProgramProbe.decodeArguments(Data([1, 0, 0])))
        XCTAssertNil(ForegroundProgramProbe.decodeArguments(kernelArguments(["kubectl"]).dropLast()))
        XCTAssertNil(ForegroundProgramProbe.decodeArguments(Data(repeating: 0, count: 65_537)))
        var badCount = Int32(10_000)
        XCTAssertNil(ForegroundProgramProbe.decodeArguments(withUnsafeBytes(of: &badCount) { Data($0) }))
    }

    // Implements: FR-NAV-11
    func testRealPTYForegroundK9sReturnsToZshWithoutMutatingStateOrJobs() throws {
        try withFixture { f in
            try f.runtime.report(f.pane.id, state: .running, agent: .claude)
            let state = try Data(contentsOf: f.stateURL)
            XCTAssertEqual(try awaitProgram(.zsh, in: f).displayProgram, .zsh)
            try f.runtime.send(f.pane.id, text: ShellQuote.quote(f.k9s.path), enter: true)
            let running = try awaitProgram(.k9s, in: f)
            XCTAssertEqual(running.agent, .claude)
            XCTAssertEqual(running.pid, f.pane.pid)
            try f.interrupt()
            XCTAssertEqual(try awaitProgram(.zsh, in: f).agent, .claude)
            XCTAssertEqual(try Data(contentsOf: f.stateURL), state)
            XCTAssertEqual(try f.runtime.list().first?.pid, f.pane.pid)
        }
    }

    // Implements: FR-NAV-11
    func testRealPTYKubectlArgumentsSelectOnlyExecWithoutConnectingToKubernetes() throws {
        try withFixture { f in
            let state = try Data(contentsOf: f.stateURL)
            try f.runtime.send(f.pane.id, text: ShellQuote.quote(f.kubectl.path) + " --context test -n test exec pod -- sh", enter: true)
            XCTAssertEqual(try awaitProgram(.kubernetesExec, in: f).pid, f.pane.pid)
            try f.interrupt()
            _ = try awaitProgram(.zsh, in: f)
            try f.runtime.send(f.pane.id, text: ShellQuote.quote(f.kubectl.path) + " --context exec get pods", enter: true)
            try awaitForegroundExecutable("kubectl", in: f)
            XCTAssertNotEqual(try f.runtime.list().first?.foregroundProgram, .kubernetesExec)
            try f.interrupt()
            _ = try awaitProgram(.zsh, in: f)
            XCTAssertEqual(try Data(contentsOf: f.stateURL), state)
        }
    }

    // Implements: FR-NAV-11
    func testBackgroundK9sCannotReplaceTheForegroundShellIcon() throws {
        try withFixture { f in
            let pidURL = f.root.appendingPathComponent("background.pid")
            try f.runtime.send(f.pane.id, text: ShellQuote.quote(f.k9s.path) + " & print -r -- $! > " + ShellQuote.quote(pidURL.path), enter: true)
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: pidURL.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            defer { _ = kill(pid, SIGTERM) }
            XCTAssertEqual(kill(pid, 0), 0)
            XCTAssertEqual(try awaitProgram(.zsh, in: f).pid, f.pane.pid)
        }
    }

    // Implements: FR-NAV-11
    func testPeriodicProbeUsesOnlyProvidedLiveLocalPanesWithoutReadingState() throws {
        try withFixture { f in
            let pane = try awaitProgram(.zsh, in: f)
            var remote = pane; remote.id = "remote"; remote.remote = RemoteReference(hostID: "fixture", sessionID: "remote")
            var dead = pane; dead.id = "dead"; dead.alive = false
            let state = try Data(contentsOf: f.stateURL)
            defer { try? TerminalRuntime.atomicWrite(state, to: f.stateURL) }
            try TerminalRuntime.atomicWrite(Data("not state".utf8), to: f.stateURL)
            XCTAssertEqual(f.runtime.foregroundPrograms(for: [pane, remote, dead]), [pane.id: .zsh])
        }
    }

    private func kernelArguments(_ argv: [String], environment: [String] = []) -> Data {
        var count = Int32(argv.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: "/tmp/kubectl\0\0".utf8)
        for argument in argv + environment { data.append(contentsOf: argument.utf8); data.append(0) }
        return data
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let pane: TerminalSession
        let k9s: URL
        let kubectl: URL
        var stateURL: URL { root.appendingPathComponent("state.json") }
        func interrupt() throws { try runtime.host.write(pane.id, Data([3])) }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/tmp/trano-fg-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let source = root.appendingPathComponent("fixture.c")
        try "#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".write(to: source, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("k9s")
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [source.path, "-o", binary.path]
        let errors = Pipe(); compile.standardError = errors
        try compile.run(); compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let kubectl = root.appendingPathComponent("kubectl")
        try FileManager.default.copyItem(at: binary, to: kubectl)
        let pane = try runtime.create(title: "Foreground fixture", cwd: root.path, shell: "/usr/bin/env",
                                      arguments: ["HOME=" + root.path, "ZDOTDIR=" + root.path, "/bin/zsh", "-f"])
        defer { try? runtime.terminate(pane.id); runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        try body(Fixture(root: root, runtime: runtime, pane: pane, k9s: binary, kubectl: kubectl))
    }

    private func awaitProgram(_ expected: TerminalProgram, in f: Fixture) throws -> TerminalSession {
        let deadline = Date().addingTimeInterval(3)
        var session = try XCTUnwrap(f.runtime.list().first)
        while session.foregroundProgram != expected && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            session = try XCTUnwrap(f.runtime.list().first)
        }
        XCTAssertEqual(session.foregroundProgram, expected)
        return session
    }

    private func awaitForegroundExecutable(_ expected: String, in f: Fixture) throws {
        let deadline = Date().addingTimeInterval(3)
        var name = ""
        repeat {
            name = try foregroundCommand(of: f)
            if name == expected { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTFail("Fixture foreground executable did not become " + expected)
    }

    /// Replaces tmux `#{pane_current_command}`: the executable name of the pane tty's foreground process group.
    private func foregroundCommand(of f: Fixture) throws -> String {
        let tty = try XCTUnwrap(try f.runtime.host.pane(f.pane.id)?.tty)
        let result = try CommandRunner.run("/bin/ps", ["-t", (tty as NSString).lastPathComponent, "-o", "stat=,comm="])
        for row in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            let fields = row.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].contains("+") else { continue }
            return (String(fields[1]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        }
        return ""
    }
}
