import XCTest
@testable import TerminalCore

final class StartupWorkspaceTests: XCTestCase {
    func testRandomWorkspaceTitlesUseLowercaseHyphenatedWordsWithoutChangingExistingTitles() {
        var layout = WorkspaceLayout()
        layout.addWorkspace(title: "My Existing Workspace")
        let original = layout

        for _ in 0..<32 {
            let name = layout.randomWorkspaceTitle()
            XCTAssertNotNil(name.range(of: "^[a-z]+-[a-z]+$", options: .regularExpression), name)
        }
        XCTAssertEqual(layout, original)
    }

    func testRandomWorkspaceTitlesRemainUniqueWithTrimmedCaseInsensitiveCollisions() {
        var layout = WorkspaceLayout()
        var names = Set<String>()

        for _ in 0..<96 {
            let name = layout.randomWorkspaceTitle()
            XCTAssertNotNil(name.range(of: "^[a-z]+-[a-z]+$", options: .regularExpression), name)
            XCTAssertTrue(names.insert(name).inserted, name)
            layout.addWorkspace(title: "  " + name.uppercased() + "\n")
        }
    }

    func testExhaustedRandomNamePoolRetainsTwoAlphabeticSegments() {
        var layout = WorkspaceLayout()
        let adjectives = ["amber", "bright", "calm", "clear", "quiet", "silver", "soft", "warm"]
        let nouns = ["cedar", "comet", "harbor", "maple", "meadow", "orbit", "pine", "river"]
        for adjective in adjectives {
            for noun in nouns {
                let base = adjective + "-" + noun
                for suffix in ["", "a", "b", "c", "d"] {
                    layout.addWorkspace(title: "  " + (base + suffix).uppercased() + "\n")
                }
            }
        }

        let name = layout.randomWorkspaceTitle()
        XCTAssertNotNil(name.range(of: "^[a-z]+-[a-z]+$", options: .regularExpression), name)
        XCTAssertFalse(layout.workspaces.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name })
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    func testEmptyStartupCreatesOneLiveTerminalInAnAutomaticallyNamedWorkspace() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let paneID = try XCTUnwrap(fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path))
        let state = try fixture.runtime.state()
        let pane = try XCTUnwrap(fixture.runtime.list().first { $0.id == paneID })
        XCTAssertTrue(pane.alive)
        XCTAssertGreaterThan(pane.pid, 0)
        XCTAssertEqual(pane.cwd, fixture.root.path)
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.layout.workspaces.count, 1)
        XCTAssertEqual(state.layout.tabs.count, 1)
        XCTAssertEqual(state.layout.focusedPaneID, paneID)
        let name = try XCTUnwrap(state.layout.workspaces.first?.title)
        XCTAssertNotNil(name.range(of: "^[a-z]+-[a-z]+$", options: .regularExpression), name)
        XCTAssertFalse(name.isEmpty)
        XCTAssertNotEqual(name, "Workspace")
        XCTAssertFalse(name.hasPrefix("Session "))
        XCTAssertNil(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path))
        XCTAssertEqual(try fixture.runtime.state().layout, state.layout)
        XCTAssertEqual(try fixture.runtime.list().map(\.pid), [pane.pid])
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    func testExistingSplitLayoutAndProcessesAreUntouched() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let first = try fixture.runtime.create(title: "First", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["60"])
        let second = try fixture.runtime.create(title: "Second", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["60"])
        try fixture.runtime.update { state in
            state.layout.addWorkspace(title: "Existing workspace")
            let tab = state.layout.addTab(paneID: first.id)
            try state.layout.split(tabID: tab, paneID: second.id, axis: .vertical)
        }
        let before = try fixture.runtime.state().layout
        XCTAssertNil(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path))
        XCTAssertEqual(try fixture.runtime.state().layout, before)
        XCTAssertEqual(try fixture.runtime.list().map(\.pid), [first.pid, second.pid])
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    func testEmptySelectedWorkspaceReopensAnExistingTabWithoutCreatingAnotherProcess() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let pane = try fixture.runtime.create(title: "Retained", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["60"])
        var tabID = ""
        try fixture.runtime.update { state in
            state.layout.addWorkspace(title: "Retained workspace")
            tabID = state.layout.addTab(paneID: pane.id)
            state.layout.addWorkspace(title: "Empty selected workspace")
        }
        _ = try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path)
        let state = try fixture.runtime.state()
        XCTAssertEqual(state.layout.selectedTabID, tabID)
        XCTAssertEqual(state.layout.focusedPaneID, pane.id)
        XCTAssertEqual(state.layout.workspaces.count, 2)
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(try fixture.runtime.list().first?.pid, pane.pid)
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    func testDetachedLivePaneIsReattachedBeforeCreatingAnotherShell() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let pane = try fixture.runtime.create(title: "Still running", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["60"])
        XCTAssertEqual(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path), pane.id)
        let state = try fixture.runtime.state()
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertEqual(state.layout.tabs.first?.panes, [pane.id])
        XCTAssertEqual(try fixture.runtime.list().first?.pid, pane.pid)
        XCTAssertTrue(try XCTUnwrap(fixture.runtime.list().first).alive)
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    func testConcurrentInitializersCreateOnlyOneWorkspaceAndShell() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let other = try TerminalRuntime(root: fixture.root)
        let lock = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do { _ = try (index == 0 ? fixture.runtime : other).ensureInitialWorkspace(cwd: fixture.root.path) }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty, errors.map(String.init(describing:)).joined(separator: "; "))
        let state = try fixture.runtime.state()
        XCTAssertEqual(state.layout.workspaces.count, 1)
        XCTAssertEqual(state.layout.tabs.count, 1)
        XCTAssertEqual(state.sessions.count, 1)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-1, FR-NAV-6, U01
    func testInvalidDirectoryLeavesRuntimeWithoutOrphanWorkspaceOrShell() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        XCTAssertThrowsError(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.appendingPathComponent("missing").path))
        XCTAssertTrue(try fixture.runtime.state().layout.workspaces.isEmpty)
        XCTAssertTrue(try fixture.runtime.list().isEmpty)
    }

    private struct Fixture { let root: URL; let runtime: TerminalRuntime }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-start-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        return Fixture(root: root, runtime: runtime)
    }

    private func dispose(_ fixture: Fixture) {
        fixture.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: fixture.root)
    }
}
