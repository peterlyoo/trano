import XCTest
@testable import TerminalCore

final class NavigationTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-5
    func testNamedSessionRequestReusesAndReopensWorkspaceWithoutNewShells() throws {
        try withSessionRuntime { runtime, root in
            let service = APIService(runtime: runtime)
            func open(_ title: String) {
                let response = service.route(APIRequest(method: "actions.perform", params: [
                    "id": .string("session.new"), "cwd": .string(root.path), "title": .string(title)
                ]))
                XCTAssertNil(response.error, response.error ?? "")
            }
            open("  Build 한글  ")
            let first = try runtime.state()
            let workspace = try XCTUnwrap(first.layout.selectedWorkspaceID)
            XCTAssertEqual(first.layout.workspaces.first { $0.id == workspace }?.title, "Build 한글")
            let tab = first.layout.selectedTabID
            let pane = first.layout.focusedPaneID
            open("Other")
            let before = try runtime.state()
            let pids = Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) })
            open("  bUiLd 한글 ")
            let reused = try runtime.state()
            XCTAssertEqual(reused.layout.workspaces.count, 2)
            XCTAssertEqual(reused.layout.selectedWorkspaceID, workspace)
            XCTAssertEqual(reused.layout.selectedTabID, tab)
            XCTAssertEqual(reused.layout.focusedPaneID, pane)
            XCTAssertEqual(reused.layout.tabs.map(\.id), before.layout.tabs.map(\.id))
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) }), pids)

            try runtime.update { $0.layout.closeWorkspace(workspace) }
            open("BUILD 한글")
            let reopened = try runtime.state()
            XCTAssertEqual(reopened.layout.selectedWorkspaceID, workspace)
            XCTAssertFalse(try XCTUnwrap(reopened.layout.workspaces.first { $0.id == workspace }).closed)
            XCTAssertEqual(reopened.layout.selectedTabID, tab)
            XCTAssertEqual(reopened.layout.focusedPaneID, pane)
            XCTAssertEqual(reopened.layout.workspaces.count, 2)
            XCTAssertEqual(reopened.layout.tabs.map(\.id), before.layout.tabs.map(\.id))
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) }), pids)
            XCTAssertTrue(try runtime.list().allSatisfy(\.alive))
        }
    }

    // Implements: FR-NAV-1, FR-NAV-5
    func testBlankSessionNamesGenerateDistinctUnusedNames() throws {
        try withSessionRuntime { runtime, root in
            try runtime.update { $0.layout.addWorkspace(title: "Session 2") }
            let service = APIService(runtime: runtime)
            for (name, expected) in [(nil, "Session 1"), (Optional(""), "Session 3"), (Optional("  \n  "), "Session 4")] {
                var params: [String: JSONValue] = ["id": .string("session.new"), "cwd": .string(root.path)]
                if let name { params["title"] = .string(name) }
                let response = service.route(APIRequest(method: "actions.perform", params: params))
                XCTAssertNil(response.error, response.error ?? "")
                let state = try runtime.state()
                XCTAssertEqual(state.layout.workspaces.first { $0.id == state.layout.selectedWorkspaceID }?.title, expected)
            }
            let state = try runtime.state()
            XCTAssertEqual(state.layout.workspaces.count, 4)
            XCTAssertEqual(Set(state.layout.workspaces.map(\.title)).count, 4)
            XCTAssertEqual(state.layout.tabs.count, 3)
            XCTAssertTrue(try runtime.list().allSatisfy(\.alive))
        }
    }

    // Implements: FR-NAV-1, FR-NAV-5
    func testExistingEmptyNamedWorkspaceGetsOneShellAndTab() throws {
        try withSessionRuntime { runtime, root in
            var workspace = ""
            try runtime.update { workspace = $0.layout.addWorkspace(title: "Empty") }
            let service = APIService(runtime: runtime)
            let request = APIRequest(method: "actions.perform", params: [
                "id": .string("session.new"), "cwd": .string(root.path), "title": .string(" empty ")
            ])
            let response = service.route(request)
            XCTAssertNil(response.error, response.error ?? "")
            let state = try runtime.state()
            XCTAssertEqual(state.layout.workspaces.count, 1)
            XCTAssertEqual(state.layout.selectedWorkspaceID, workspace)
            XCTAssertEqual(state.layout.currentTabs.count, 1)
            XCTAssertEqual(state.sessions.count, 2)
            let pids = Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) })
            XCTAssertNil(service.route(request).error)
            XCTAssertEqual(try runtime.state().layout, state.layout)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) }), pids)
        }
    }

    // Implements: FR-NAV-1, FR-NAV-5
    func testInvalidSessionNameCannotMutateTargetSelectionOrCreateShell() throws {
        try withSessionRuntime { runtime, root in
            var target = ""
            try runtime.update {
                target = $0.layout.addWorkspace(title: "Target")
                $0.layout.addWorkspace(title: "Current")
            }
            let service = APIService(runtime: runtime)
            for title in [String(repeating: "x", count: 201), "line\nbreak", "tab\tname", "nul\0name", "control\u{7f}name"] {
                let before = try JSONValue.encoded(runtime.state())
                let pids = Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) })
                let response = service.route(APIRequest(method: "actions.perform", params: [
                    "id": .string("session.new"), "cwd": .string(root.path),
                    "title": .string(title), "workspaceID": .string(target)
                ]))
                XCTAssertNotNil(response.error)
                XCTAssertEqual(try JSONValue.encoded(runtime.state()), before)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) }), pids)
            }
            for title in [JSONValue.bool(true), .number(42), .array([]), .object([:]), .null] {
                let before = try JSONValue.encoded(runtime.state())
                let response = service.route(APIRequest(method: "actions.perform", params: [
                    "id": .string("session.new"), "cwd": .string(root.path),
                    "title": title, "workspaceID": .string(target)
                ]))
                XCTAssertNotNil(response.error)
                XCTAssertEqual(try JSONValue.encoded(runtime.state()), before)
            }
        }
    }

    private func withSessionRuntime(_ body: (TerminalRuntime, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-names-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer {
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            try? FileManager.default.removeItem(at: root)
        }
        _ = try runtime.create(title: "Fixture", cwd: root.path, shell: "/bin/sleep", arguments: ["60"])
        for name in ["HOME", "ZDOTDIR"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime.executable)
            process.arguments = ["-S", runtime.socketPath, "set-environment", "-g", name, root.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try body(runtime, root)
    }

    // Implements: FR-NAV-5
    func testLauncherReusesProjectWorkspaceWithoutReusingItsPTY() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-launch-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer {
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let first = try runtime.launch(cwd: root.path)
        let second = try runtime.launch(cwd: root.path)
        XCTAssertEqual(first.workspaceID, second.workspaceID)
        XCTAssertNotEqual(first.pane.id, second.pane.id)
        XCTAssertEqual(try runtime.state().layout.currentTabs.count, 2)
        XCTAssertThrowsError(try runtime.launch(cwd: root.path, agent: .claude, prompt: "No provider may start without a configured helper"))
        XCTAssertEqual(try runtime.list().count, 2)
    }
    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-5
    func testRealShellsSurviveWorkspaceAndTabActionsThroughAPI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-nav-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer {
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let service = APIService(runtime: runtime)
        func action(_ id: String) throws {
            let response = service.route(APIRequest(method: "actions.perform", params: ["id": .string(id), "cwd": .string(root.path)]))
            XCTAssertNil(response.error, response.error ?? "")
        }
        try action("session.new")
        try action("client.tab.new")
        try action("pane.split.down")
        let first = try runtime.state().layout.selectedWorkspaceID
        let ids = try runtime.list().map(\.id)
        let pids = try runtime.list().map(\.pid)
        try action("session.new")
        try action("session.previous")
        XCTAssertEqual(try runtime.state().layout.selectedWorkspaceID, first)
        try action("client.tab.close")
        try action("client.tab.restore")
        let after = try runtime.list().filter { ids.contains($0.id) }
        XCTAssertEqual(after.map(\.pid), pids)
        XCTAssertTrue(after.allSatisfy(\.alive))
        let uiOnly = service.route(APIRequest(method: "actions.perform", params: ["id": .string("pane.insert_path")]))
        XCTAssertTrue(uiOnly.error?.contains("requiresUI") == true)
        let catalog = service.route(APIRequest(method: "actions.list"))
        guard case .array(let rows)? = catalog.result else { return XCTFail("Missing action catalog") }
        XCTAssertTrue(rows.contains { $0["id"] == .string("pane.insert_path") })
        let closedPane = try runtime.state().layout.focusedPaneID!
        try action("client.tab.close")
        try runtime.terminate(closedPane)
        try action("client.tab.restore")
        XCTAssertFalse(try runtime.state().layout.tabs.flatMap(\.panes).contains(closedPane))
    }

    // Implements: FR-NAV-1, FR-NAV-5
    func testTargetedActionUsesLiveDirectoryAndDoesNotFollowOtherWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("trano-target-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer {
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let directory = root.appendingPathComponent("한글 folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pane = try runtime.create(title: "Original", cwd: root.path, arguments: ["-f"])
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let workspaceID = try runtime.state().layout.selectedWorkspaceID!
        try runtime.send(pane.id, text: "cd " + ShellQuote.quote(directory.path), enter: true)
        for _ in 0..<50 {
            if URL(fileURLWithPath: try runtime.workingDirectory(pane.id)).standardizedFileURL == directory.standardizedFileURL { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(URL(fileURLWithPath: try runtime.workingDirectory(pane.id)).standardizedFileURL, directory.standardizedFileURL)
        try runtime.performAction(.newSession, cwd: root.path)
        let response = APIService(runtime: runtime).route(APIRequest(method: "actions.perform", params: [
            "id": .string("client.tab.new"), "workspaceID": .string(workspaceID)
        ]))
        XCTAssertNil(response.error)
        let state = try runtime.state()
        XCTAssertEqual(state.layout.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(state.layout.currentTabs.count, 2)
        XCTAssertEqual(state.sessions.last?.cwd, directory.path)
    }

    // Implements: FR-NAV-1, FR-NAV-4
    func testSessionAndTabCyclesAreIndependentAndRestoreFocus() throws {
        var layout = WorkspaceLayout()
        let first = layout.addWorkspace(title: "One")
        let a = layout.addTab(paneID: "a")
        let b = layout.addTab(paneID: "b")
        try layout.split(tabID: b, paneID: "b2", axis: .horizontal)
        let second = layout.addWorkspace(title: "Two")
        let c = layout.addTab(paneID: "c")
        try layout.selectWorkspace(first)
        XCTAssertEqual(layout.selectedTabID, b)
        XCTAssertEqual(layout.focusedPaneID, "b2")
        layout.cycleTab(1)
        XCTAssertEqual(layout.selectedTabID, a)
        layout.cycleWorkspace(1)
        XCTAssertEqual(layout.selectedWorkspaceID, second)
        XCTAssertEqual(layout.selectedTabID, c)
        layout.cycleWorkspace(1)
        XCTAssertEqual(layout.selectedTabID, a)
        XCTAssertEqual(Set(layout.tabs.flatMap(\.panes)), Set(["a", "b", "b2", "c"]))
        layout.closeTab(a)
        XCTAssertEqual(layout.selectedTabID, b)
        layout.restoreTab()
        XCTAssertEqual(layout.selectedTabID, a)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout)), layout)
    }

    // Implements: FR-NAV-1
    func testLegacyLayoutMigratesWithoutChangingPaneOrTabIDs() throws {
        let old = Data(#"{"tabs":[{"id":"tab","title":"Terminal","panes":["pane"],"axis":"horizontal"}],"selectedTabID":"tab","focusedPaneID":"pane"}"#.utf8)
        let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: old)
        XCTAssertEqual(layout.workspaces.count, 1)
        XCTAssertEqual(layout.currentTabs.map(\.id), ["tab"])
        XCTAssertEqual(layout.focusedPaneID, "pane")
    }

    // Implements: FR-NAV-2, FR-NAV-3
    func testPathInsertionAndKeyMapHaveNoAmbiguousExecution() throws {
        XCTAssertEqual(try PathInsertion.text(paths: ["/tmp/한글 file", "/tmp/a'b"]), "'/tmp/한글 file' '/tmp/a'\\''b' ")
        XCTAssertThrowsError(try PathInsertion.text(paths: ["/tmp/name\ncommand"]))
        XCTAssertThrowsError(try PathInsertion.text(paths: []))
        let bindings = ActionCatalog.all.flatMap(\.bindings)
        XCTAssertEqual(Set(bindings).count, bindings.count)
        XCTAssertEqual(ActionCatalog.action(for: "cmd+k")?.id, "session.switch")
        XCTAssertEqual(ActionCatalog.action(for: "cmd+shift+p")?.id, "client.palette.toggle")
        XCTAssertNotNil(ActionCatalog.all.first { $0.id == "pane.insert_path" })
        XCTAssertNotEqual(ActionCatalog.action(for: "cmd+shift+]")?.id, ActionCatalog.action(for: "cmd+alt+]")?.id)
    }
}
