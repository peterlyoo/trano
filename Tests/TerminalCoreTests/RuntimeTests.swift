import XCTest
@testable import TerminalCore

final class RuntimeTests: XCTestCase {
    // Implements: FR-CORE-2, FR-CORE-3
    func testLiteralSemicolonAndLivePID() throws {
        let directory = root.appendingPathComponent("trailing;")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pane = try runtime.create(title: "Literal", cwd: directory.path, arguments: ["-f"])
        try runtime.send(pane.id, text: "stty -echo; read -r literal; printf '%s' \"$literal\" > received", enter: true)
        Thread.sleep(forTimeInterval: 0.2)
        try runtime.send(pane.id, text: "backslash\\;", enter: true)
        let result = directory.appendingPathComponent("received")
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: result.path) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "backslash\\;")
        try runtime.update { $0.sessions[0].pid = -1 }
        XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
    }
    var root: URL!
    var runtime: TerminalRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("at-" + UUID().uuidString.prefix(8))
        runtime = try TerminalRuntime(root: root)
    }

    override func tearDownWithError() throws {
        for session in (try? runtime.list()) ?? [] { try runtime.terminate(session.id) }
        try? FileManager.default.removeItem(at: root)
    }

    // Implements: FR-CORE-1, FR-CORE-2, NFR-CORE-2
    func testPersistentShellAndQuotedWorkingDirectory() throws {
        let cwd = root.appendingPathComponent("한글 path 'quoted'")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let session = try runtime.create(title: "test", cwd: cwd.path, shell: "/bin/zsh", arguments: ["-f"])
        XCTAssertGreaterThan(session.pid, 0)
        try runtime.send(session.id, text: "sleep 0.2; printf '\\nPERSIST_SENTINEL_%s\\n' '한글'", enter: true)
        let fresh = try TerminalRuntime(root: root)
        let deadline = Date().addingTimeInterval(5)
        var output = ""
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            output = try fresh.capture(session.id, lines: 100)
        } while !output.contains("PERSIST_SENTINEL_한글") && Date() < deadline
        XCTAssertTrue(output.contains("PERSIST_SENTINEL_한글"))
        XCTAssertEqual(try fresh.list().first?.pid, session.pid)
        XCTAssertEqual(URL(fileURLWithPath: try fresh.workingDirectory(session.id)).resolvingSymlinksInPath(), cwd.resolvingSymlinksInPath())
    }

    // Implements: FR-CORE-2, FR-CORE-7
    func testValidationAndExplicitTerminationIsolation() throws {
        XCTAssertThrowsError(try runtime.create(title: "bad", cwd: "/path/does/not/exist"))
        XCTAssertThrowsError(try runtime.capture("; kill-server", lines: 20))
        let first = try runtime.create(title: "first", cwd: root.path, shell: "/bin/zsh", arguments: ["-f"])
        let second = try runtime.create(title: "second", cwd: root.path, shell: "/bin/zsh", arguments: ["-f"])
        try runtime.terminate(first.id)
        XCTAssertEqual(try runtime.list().map(\.id), [second.id])
        XCTAssertThrowsError(try runtime.send(first.id, text: "echo nope", enter: true))
        XCTAssertThrowsError(try runtime.capture(second.id, lines: 100_001))
    }

    // Implements: FR-CORE-7, NFR-CORE-2
    func testStructuredStatusPersistsWithoutInferringCompletion() throws {
        let session = try runtime.create(title: "agent", cwd: root.path, shell: "/bin/zsh", arguments: ["-f"])
        XCTAssertEqual(session.activity.state, .unknown)
        try runtime.report(session.id, state: .blocked, reason: "permission", agent: .claude)
        let restored = try TerminalRuntime(root: root).list().first!
        XCTAssertEqual(restored.activity.state, .blocked)
        XCTAssertEqual(restored.activity.reason, "permission")
        XCTAssertEqual(restored.agent, .claude)
        XCTAssertEqual(restored.activity.source, "explicit")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    // Implements: FR-CORE-4
    func testMovingPaneRetainsIdentityAndRejectsUnknownTarget() throws {
        var layout = WorkspaceLayout()
        let first = layout.addTab(paneID: "first")
        let second = layout.addTab(paneID: "second")
        try layout.split(tabID: first, paneID: "third", axis: .horizontal)
        try layout.move(paneID: "third", to: second)
        XCTAssertEqual(layout.tabs.first(where: { $0.id == first })?.panes, ["first"])
        XCTAssertEqual(layout.tabs.first(where: { $0.id == second })?.panes, ["second", "third"])
        let before = layout
        XCTAssertThrowsError(try layout.move(paneID: "first", to: "missing"))
        XCTAssertEqual(layout, before)
    }
    // Implements: NFR-CORE-2
    func testUnmanagedDirectoryIsNotAdoptedOrChanged() throws {
        let unmanaged = root.appendingPathComponent("unmanaged")
        try FileManager.default.createDirectory(at: unmanaged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data("untouched".utf8).write(to: unmanaged.appendingPathComponent("user-file"))
        XCTAssertThrowsError(try TerminalRuntime(root: unmanaged))
        let permissions = try FileManager.default.attributesOfItem(atPath: unmanaged.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o755)
    }

    // Implements: FR-CORE-4, FR-CORE-5
    func testMixedSplitsResizeAndMovePreserveTheOtherBranch() throws {
        var layout = WorkspaceLayout()
        let tab = layout.addTab(paneID: "a")
        try layout.split(tabID: tab, paneID: "b", axis: .horizontal)
        try layout.split(tabID: tab, paneID: "c", axis: .vertical)
        guard case .split(_, .horizontal, _, .pane("a"), .split(let inner, .vertical, _, .pane("b"), .pane("c"))) = layout.tabs[0].tree else {
            return XCTFail("Splitting the focused pane must preserve the other branch")
        }
        try layout.resize(splitID: inner, ratio: 0.99)
        XCTAssertEqual(layout.tabs[0].tree.ratio(for: inner), 0.85)
        let restored = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored, layout)
        let destination = layout.addTab(paneID: "d")
        try layout.move(paneID: "c", to: destination)
        XCTAssertEqual(layout.tabs[0].panes, ["a", "b"])
        XCTAssertEqual(layout.tabs[1].panes, ["d", "c"])
        XCTAssertNil(layout.tabs[0].tree.ratio(for: inner))
    }

}
