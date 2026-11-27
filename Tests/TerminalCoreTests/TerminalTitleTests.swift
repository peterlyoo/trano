import XCTest
@testable import TerminalCore

final class TerminalTitleTests: XCTestCase {
    // Implements: FR-NAV-9
    func testTitleFormattingCannotResolveHostNames() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: project.appendingPathComponent("Sources/TerminalCore/TerminalTitleMetadata.swift"), encoding: .utf8)
        for forbidden in ["processInfo.hostName", "NSHost", "getaddrinfo", "gethostbyname"] {
            XCTAssertFalse(source.contains(forbidden), "Title formatting must remain independent of network name resolution")
        }
    }

    // Implements: FR-NAV-9
    func testLegacySessionDecodesWithoutTerminalTitle() throws {
        let legacy = Data("{\"id\":\"pane\",\"title\":\"Stored title\",\"cwd\":\"/tmp\",\"pid\":1,\"host\":\"local\",\"agent\":\"shell\",\"activity\":{\"state\":\"unknown\",\"reason\":\"\",\"source\":\"unknown\",\"updatedAt\":0},\"createdAt\":0,\"alive\":true}".utf8)
        let session = try JSONDecoder().decode(TerminalSession.self, from: legacy)
        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.displayTitle, "Stored title")
    }

    // Implements: FR-NAV-9
    func testDisplayTitlePreservesStoredNameAndFallsBackForBlankMetadata() {
        var session = TerminalSession(id: "pane", title: "Named pane", cwd: "/tmp", pid: 1)
        for title in [nil, "", " \n\t "] {
            session.terminalTitle = title
            XCTAssertEqual(session.displayTitle, "Named pane")
            XCTAssertEqual(session.title, "Named pane")
        }
        session.terminalTitle = "  Claude · 세션 작업  "
        XCTAssertEqual(session.displayTitle, "Claude · 세션 작업")
        XCTAssertEqual(session.title, "Named pane")
    }

    // Implements: FR-NAV-9
    func testDisplayTitleIsBoundedWithoutBreakingUnicodeAndStripsControls() {
        var session = TerminalSession(id: "pane", title: "Fallback", cwd: "/tmp", pid: 1)
        session.terminalTitle = "한글\u{1b}\n\t작업\u{7f}👩‍💻"
        XCTAssertEqual(session.displayTitle, "한글작업👩‍💻")
        session.terminalTitle = String(repeating: "가나👩‍💻", count: 201)
        XCTAssertEqual(session.displayTitle.count, 200)
        XCTAssertTrue(session.displayTitle.hasPrefix("가나👩‍💻"))
    }

    // Implements: FR-NAV-9
    func testOversizedSingleGraphemeFallsBackWithoutLargeDisplayMetadata() {
        var session = TerminalSession(id: "pane", title: "Stored fallback", cwd: "/tmp", pid: 1)
        session.terminalTitle = "X" + String(repeating: "\u{0301}", count: 5000)
        XCTAssertEqual(session.terminalTitle?.count, 1)
        XCTAssertTrue(session.displayTitle == "Stored fallback")
        session.terminalTitle = String(repeating: "X", count: 8193)
        XCTAssertTrue(session.displayTitle == "Stored fallback")
    }

    // Implements: FR-NAV-9
    func testOversizedOSCTitleIsRejectedBeforeDisplay() throws {
        try withRuntime { runtime in
            let pane = try runtime.create(title: "Stored fallback", cwd: runtime.root.path, shell: "/bin/sleep", arguments: ["30"])
            let title = "X" + String(repeating: "\u{0301}", count: 5000)
            try runtime.setPaneTitleThroughTTY(pane.id, title)
            let observed = try runtime.waitForPaneTitle(pane.id) { $0 != nil }
            XCTAssertGreaterThan(try XCTUnwrap(observed).utf8.count, 8192)
            let projected = try XCTUnwrap(runtime.list().first)
            XCTAssertNil(projected.terminalTitle.map { $0.utf8.count })
            XCTAssertTrue(projected.displayTitle == "Stored fallback")
            XCTAssertEqual(projected.pid, pane.pid)
        }
    }

    // Implements: FR-NAV-9
    func testOSCZeroBELAndOSCTwoSTUpdateExistingPaneWithoutStateWrites() throws {
        try withRuntime { runtime in
            let pane = try runtime.create(title: "Stored fallback", cwd: runtime.root.path, shell: "/bin/sh", arguments: ["-c", "printf '\\033]0;Claude · 한글 제목\\007'; exec /bin/sleep 30"])
            let stateURL = runtime.root.appendingPathComponent("state.json")
            let original = try Data(contentsOf: stateURL)
            let first = try awaitTitle("Claude · 한글 제목", pane: pane.id, runtime: runtime)
            XCTAssertEqual(first.terminalTitle, "Claude · 한글 제목")
            XCTAssertEqual(first.title, "Stored fallback")
            XCTAssertEqual(first.pid, pane.pid)
            XCTAssertEqual(try Data(contentsOf: stateURL), original)
            let tty = try XCTUnwrap(try runtime.host.pane(pane.id)?.tty)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tty))
            try handle.write(contentsOf: Data("\u{1b}]2;Codex · 새 제목\u{1b}\\".utf8))
            try handle.close()
            let second = try awaitTitle("Codex · 새 제목", pane: pane.id, runtime: runtime)
            XCTAssertEqual(second.pid, pane.pid)
            XCTAssertEqual(second.title, "Stored fallback")
            XCTAssertEqual(try Data(contentsOf: stateURL), original)
            XCTAssertNil(try runtime.state().sessions.first?.terminalTitle)
        }
    }

    // Implements: FR-NAV-9
    func testTitlePipesAndAttemptedNewlinesCannotForgeAnotherPaneOrPID() throws {
        try withRuntime { runtime in
            let first = try runtime.create(title: "First", cwd: runtime.root.path, shell: "/bin/sleep", arguments: ["30"])
            let second = try runtime.create(title: "Second", cwd: runtime.root.path, shell: "/bin/sleep", arguments: ["30"])
            let stateURL = runtime.root.appendingPathComponent("state.json")
            let original = try Data(contentsOf: stateURL)
            let title = "Codex | 한글 | pane title"
            try runtime.setPaneTitleThroughTTY(first.id, title)
            XCTAssertEqual(try awaitTitle(title, pane: first.id, runtime: runtime).displayTitle, title)
            try runtime.setPaneTitleThroughTTY(first.id, "bad\n" + second.id + "|123|0|forged")
            _ = try runtime.waitForPaneTitle(first.id) { $0 != title }
            let rows = try runtime.list()
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.first { $0.id == first.id }?.pid, first.pid)
            XCTAssertEqual(rows.first { $0.id == second.id }?.pid, second.pid)
            XCTAssertEqual(rows.first { $0.id == second.id }?.displayTitle, "Second")
            XCTAssertFalse(rows.first { $0.id == first.id }?.displayTitle.contains("\n") ?? true)
            XCTAssertEqual(try Data(contentsOf: stateURL), original)
        }
    }

    // Implements: FR-NAV-9
    func testUntitledPaneUsesStoredName() throws {
        try withRuntime { runtime in
            let pane = try runtime.create(title: "Named legacy pane", cwd: runtime.root.path, shell: "/bin/sleep", arguments: ["30"])
            XCTAssertNil(try runtime.host.pane(pane.id)?.title.flatMap(TerminalTitleMetadata.normalize))
            let projected = try XCTUnwrap(runtime.list().first)
            XCTAssertNil(projected.terminalTitle)
            XCTAssertEqual(projected.displayTitle, "Named legacy pane")
        }
    }

    // Implements: FR-NAV-9
    func testUntitledAndExitedPaneUseStoredFallback() throws {
        try withRuntime { runtime in
            let pane = try runtime.create(title: "Fallback", cwd: runtime.root.path, shell: "/bin/sleep", arguments: ["30"])
            let live = try XCTUnwrap(runtime.list().first)
            XCTAssertNil(live.terminalTitle)
            XCTAssertEqual(live.displayTitle, "Fallback")
            try runtime.killPaneProcess(pane.id)
            let exited = try XCTUnwrap(runtime.list().first)
            XCTAssertFalse(exited.alive)
            XCTAssertEqual(exited.displayTitle, "Fallback")
        }
    }

    private func awaitTitle(_ title: String, pane: String, runtime: TerminalRuntime) throws -> TerminalSession {
        let deadline = Date().addingTimeInterval(3)
        var result = try XCTUnwrap(runtime.list().first { $0.id == pane })
        while result.displayTitle != title && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            result = try XCTUnwrap(runtime.list().first { $0.id == pane })
        }
        XCTAssertEqual(result.displayTitle, title)
        return result
    }

    private func withRuntime(_ work: (TerminalRuntime) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/tmp/trano-title-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        defer {
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        try work(runtime)
    }
}
