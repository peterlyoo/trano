import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TabPresentationTests: XCTestCase {
    // Implements: FR-NAV-9
    func testReportedTerminalTitleWinsForAutomaticTabsAndManualNamesRemain() {
        var session = pane("a", "Stored title", .codex)
        session.terminalTitle = "Codex · 실제 세션 제목"
        var tab = split([session.id])
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [session]).title, "Codex · 실제 세션 제목")
        tab.title = "Release work"
        XCTAssertEqual(TabPresentation(tab: tab, sessions: [session]).title, "Release work")
        XCTAssertEqual(session.title, "Stored title")
    }

    // Implements: FR-NAV-9
    @MainActor func testBothAgentOrdersRenderInTheSameCompactSlot() throws {
        let preview = VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) { TabAgentIcons(agents: [.codex, .claude]); Text("Codex · API 인증 오류 수정") }
            HStack(spacing: 9) { TabAgentIcons(agents: [.claude, .codex]); Text("Claude · 터미널 UI 개선") }
        }.font(.system(size: 12)).foregroundStyle(.white)
            .frame(width: 320, alignment: .leading).padding(20).background(Color(white: 0.09))
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 360, accuracy: 0.5)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertEqual(bitmap.pixelsWide, 1080)
        if let path = ProcessInfo.processInfo.environment["TRANO_TAB_SNAPSHOT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    // Implements: FR-NAV-9
    @MainActor func testFinalTitleEventWhileReadIsInFlightIsNotLost() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-title-ui-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Fallback", cwd: root.path, shell: "/bin/sleep", arguments: ["30"])
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let store = AppStore(runtime: runtime)
        let source = TranoView(frame: .zero)
        source.paneID = pane.id
        store.terminalViews[pane.id] = source
        let releaseQueue = DispatchSemaphore(value: 0)
        defer {
            releaseQueue.signal()
            store.terminalViews.removeAll()
            try? runtime.terminate(pane.id)
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        let ready = Date().addingTimeInterval(3)
        while store.loading && Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        try await Task.sleep(for: .milliseconds(300))
        let entered = DispatchSemaphore(value: 0)
        store.queue.async { entered.signal(); releaseQueue.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try runtime.setPaneTitleThroughTTY(pane.id, "First title")
        XCTAssertEqual(try runtime.waitForPaneTitle(pane.id) { $0 == "First title" }, "First title")
        XCTAssertTrue(store.terminalViews[pane.id] === source)
        store.terminalTitleChanged(source: source)
        try await Task.sleep(for: .milliseconds(150))
        let readFinished = DispatchSemaphore(value: 0)
        store.queue.async { readFinished.signal() }
        releaseQueue.signal()
        XCTAssertEqual(readFinished.wait(timeout: .now() + 2), .success)
        try runtime.setPaneTitleThroughTTY(pane.id, "Final title")
        XCTAssertEqual(try runtime.waitForPaneTitle(pane.id) { $0 == "Final title" }, "Final title")
        store.terminalTitleChanged(source: source)
        let deadline = Date().addingTimeInterval(2)
        while store.sessions.first?.displayTitle != "Final title" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.sessions.first?.displayTitle, "Final title")
        XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
    }

    // Implements: FR-NAV-9
    func testFocusedProviderIsFirstAndTitleTracksFocusedPaneWithoutReorderingLayout() throws {
        let claude = pane("a", "Claude conversation", .claude)
        let codex = pane("b", "한글 Codex 제목", .codex)
        var tab = split([claude.id, codex.id])
        let before = tab.tree
        for (focus, title, agents) in [("a", claude.title, [TerminalProgram.claude, .codex]), ("b", codex.title, [.codex, .claude])] {
            tab.focusedPaneID = focus
            let display = TabPresentation(tab: tab, sessions: [codex, claude])
            XCTAssertEqual(display.title, title)
            XCTAssertEqual(display.programs, agents)
            XCTAssertEqual(display.focusedPaneID, focus)
            XCTAssertEqual(tab.tree, before)
        }
    }

    // Implements: FR-NAV-9
    func testDistinctProvidersRememberInactiveFocusAndRespectManualTabName() {
        let sessions = [pane("a", "First", .claude), pane("b", "Second", .claude), pane("c", "Third", .codex), pane("d", "Shell", .shell)]
        var tab = split(sessions.map(\.id))
        tab.focusedPaneID = "c"
        var display = TabPresentation(tab: tab, sessions: sessions, focusedPaneID: "outside-tab")
        XCTAssertEqual(display.title, "Third")
        XCTAssertEqual(display.programs, [.codex, .claude, .shell])
        tab.title = "My workspace tab"
        display = TabPresentation(tab: tab, sessions: sessions, focusedPaneID: "b")
        XCTAssertEqual(display.title, "My workspace tab")
        XCTAssertEqual(display.programs, [.claude, .codex, .shell])
        XCTAssertEqual(display.focusedPaneID, "b")
    }

    // Implements: FR-NAV-9
    func testMissingAndStalePaneFocusFallsBackToAnExistingPane() {
        var tab = split(["missing", "available"])
        tab.focusedPaneID = "stale"
        let available = pane("available", "Available", .codex)
        let display = TabPresentation(tab: tab, sessions: [pane("outsider", "Wrong", .claude), available])
        XCTAssertEqual(display.title, "Available")
        XCTAssertEqual(display.programs, [.codex])
        XCTAssertEqual(display.focusedPaneID, "available")
        let empty = TabPresentation(tab: tab, sessions: [])
        XCTAssertEqual(empty.title, "Terminal")
        XCTAssertEqual(empty.programs, [.shell])
    }

    // Implements: FR-NAV-9
    @MainActor func testNativeTabFocusChangesKeepRenderersClientsJobsAndHeaderGeometry() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-tabid-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let first = try runtime.create(title: "Claude conversation", cwd: root.path, shell: "/bin/sleep", arguments: ["90"])
        let second = try runtime.create(title: "Codex conversation", cwd: root.path, shell: "/bin/sleep", arguments: ["90"])
        try runtime.update {
            $0.layout.addTab(paneID: first.id)
            try $0.layout.split(tabID: $0.layout.selectedTabID!, paneID: second.id, axis: .horizontal)
        }
        try runtime.report(first.id, state: .running, agent: .claude)
        try runtime.report(second.id, state: .running, agent: .codex)
        let store = AppStore(runtime: runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        window.contentView = hosting
        defer {
            let views = Array(store.terminalViews.values)
            store.terminalViews.removeAll()
            views.forEach { $0.terminate() }
            window.close()
            for id in [first.id, second.id] { try? runtime.terminate(id) }
            try? FileManager.default.removeItem(at: root)
        }
        try await settle(hosting) { !store.loading && [first.id, second.id].allSatisfy { store.terminalViews[$0]?.process.running == true } }
        let tabID = try XCTUnwrap(store.state.layout.selectedTabID)
        let views = store.terminalViews
        let clients = views.mapValues { $0.process.shellPid }
        let pids = Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) })
        let tree = store.selectedTab?.tree
        var closeFrame: NSRect?
        for (id, title, agents) in [(first.id, first.title, "claude,codex"), (second.id, second.title, "codex,claude"), (first.id, first.title, "claude,codex")] {
            store.focus(id)
            try await settle(hosting) {
                self.region(hosting, "tab-title-" + tabID)?.accessibilityLabel() == title && self.region(hosting, "tab-agents-" + tabID)?.accessibilityLabel() == agents
            }
            XCTAssertEqual(store.focusedID, id)
            XCTAssertEqual(store.selectedTab?.tree, tree)
            XCTAssertEqual(region(hosting, "tab-title-" + tabID)?.accessibilityLabel(), title)
            let icons = try XCTUnwrap(region(hosting, "tab-agents-" + tabID))
            XCTAssertEqual(icons.frame.width, 20, accuracy: 0.5)
            XCTAssertEqual(icons.frame.height, 16, accuracy: 0.5)
            let close = try XCTUnwrap(region(hosting, "tab-close-" + tabID))
            let frame = close.convert(close.bounds, to: hosting)
            if let prior = closeFrame { XCTAssertEqual(frame.minY, prior.minY, accuracy: 0.5); XCTAssertEqual(frame.size, prior.size) }
            closeFrame = frame
            for paneID in [first.id, second.id] {
                XCTAssertTrue(store.terminalViews[paneID] === views[paneID])
                XCTAssertEqual(store.terminalViews[paneID]?.process.shellPid, clients[paneID])
            }
            XCTAssertEqual(TabActivitySnapshot(tab: store.selectedTab!, sessions: store.sessions).title, title)
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) }), pids)
        try await Task.sleep(for: .milliseconds(500))
        let updatedTitle = "Codex · 새 세션 제목"
        let revision = try runtime.state().revision
        try runtime.setPaneTitleThroughTTY(first.id, updatedTitle)
        XCTAssertEqual(try runtime.waitForPaneTitle(first.id) { $0 == updatedTitle }, updatedTitle)
        try await settle(hosting) { self.region(hosting, "tab-title-" + tabID)?.accessibilityLabel() == updatedTitle }
        XCTAssertEqual(try runtime.state().revision, revision)
        XCTAssertEqual(store.focusedID, first.id)
        XCTAssertTrue(store.terminalViews[first.id] === views[first.id])
        XCTAssertEqual(store.terminalViews[first.id]?.process.shellPid, clients[first.id])
    }

    private func pane(_ id: String, _ title: String, _ agent: AgentKind) -> TerminalSession {
        var value = TerminalSession(id: id, title: title, cwd: "/tmp", pid: 123)
        value.agent = agent
        return value
    }

    private func split(_ ids: [String]) -> TerminalTab {
        var tab = TerminalTab(paneID: ids[0])
        tab.tree = ids.dropFirst().reduce(.pane(ids[0])) { $0.inserting($1, beside: $0.panes.last!, axis: .horizontal) }
        return tab
    }

    @MainActor private func region(_ view: NSView, _ id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region($0, id) }.first
    }

    @MainActor private func settle(_ hosting: NSView, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Tab presentation did not settle")
    }
}
