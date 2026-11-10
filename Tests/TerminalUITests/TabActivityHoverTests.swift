import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TabActivityHoverTests: XCTestCase {
    // Implements: FR-HOVER-1, FR-HOVER-4
    func testSnapshotIncludesAllPanesAndOrdersReportedChildrenUnderTheirParent() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var first = session("first", agent: .claude, state: .running, timestamp: timestamp)
        first.agentTasks = [
            task("nested", parent: "child", state: .blocked, timestamp: timestamp),
            task("child", state: .running, timestamp: timestamp),
            task("done", state: .done, timestamp: timestamp)
        ]
        let second = session("second", agent: .codex, state: .error, timestamp: timestamp)
        var tab = TerminalTab(paneID: first.id)
        tab.tree = .split(id: "split", axis: .horizontal, ratio: 0.5, first: .pane(first.id), second: .pane(second.id))

        let snapshot = TabActivitySnapshot(tab: tab, sessions: [second, first])

        XCTAssertEqual(snapshot.panes.map(\.id), ["first", "second"])
        XCTAssertEqual(snapshot.panes[0].root.agent, .claude)
        XCTAssertEqual(snapshot.panes[0].root.state, .running)
        XCTAssertEqual(snapshot.panes[0].root.source, "provider-hook")
        XCTAssertEqual(snapshot.panes[0].root.updatedAt, timestamp)
        XCTAssertEqual(snapshot.panes[0].children.map(\.id), ["child", "nested", "done"])
        XCTAssertEqual(snapshot.panes[0].children.map(\.depth), [1, 2, 1])
        XCTAssertEqual(snapshot.panes[0].children[1].parentID, "child")
        XCTAssertEqual(snapshot.panes[0].children[1].state, .blocked)
        XCTAssertEqual(snapshot.panes[0].children[1].source, "child-hook")
        XCTAssertEqual(snapshot.panes[0].children[1].updatedAt, timestamp)
        XCTAssertEqual(snapshot.panes[1].root.agent, .codex)
        XCTAssertEqual(snapshot.panes[1].root.state, .error)
    }

    // Implements: FR-HOVER-1, FR-HOVER-4
    func testSnapshotKeepsClosedDisconnectedMissingAndUnreportedStatesHonest() {
        var closed = session("closed", agent: .claude, state: .running)
        closed.alive = false
        var remote = session("remote", agent: .codex, state: .running)
        remote.alive = false
        remote.remote = RemoteReference(hostID: "test-host", sessionID: "remote-session")
        var tab = TerminalTab(paneID: closed.id)
        tab.tree = .split(id: "a", axis: .horizontal, ratio: 0.5, first: .pane(closed.id), second:
            .split(id: "b", axis: .vertical, ratio: 0.5, first: .pane(remote.id), second: .pane("missing")))

        let snapshot = TabActivitySnapshot(tab: tab, sessions: [closed, remote])

        XCTAssertEqual(snapshot.panes.map(\.availability), [.closed, .disconnected, .unavailable])
        XCTAssertEqual(snapshot.panes[0].root.state, .running)
        XCTAssertEqual(snapshot.panes[0].childSummary, "No subagents reported")
        XCTAssertTrue(snapshot.panes[0].children.isEmpty)
        XCTAssertNil(snapshot.panes[2].root.agent)
        XCTAssertEqual(snapshot.panes[2].root.state, .unknown)
        XCTAssertNil(snapshot.panes[2].root.updatedAt)
        XCTAssertEqual(snapshot.panes[2].root.source, "unavailable")
    }

    // Implements: FR-HOVER-1
    func testMalformedChildParentsDoNotHideRowsOrLoop() {
        var pane = session("pane", agent: .codex, state: .idle)
        pane.agentTasks = [task("a", parent: "b"), task("b", parent: "a"), task("orphan", parent: "absent")]
        let snapshot = TabActivitySnapshot(tab: TerminalTab(paneID: pane.id), sessions: [pane])
        XCTAssertEqual(Set(snapshot.panes[0].children.map(\.id)), Set(["a", "b", "orphan"]))
        XCTAssertEqual(snapshot.panes[0].children.count, 3)
    }

    // Implements: FR-HOVER-1, FR-HOVER-2
    @MainActor func testNativeHoverOpensAfterDelayAndRendersLiveUpdatesWithoutSelectingOrTakingFocus() async throws {
        let fixture = try makeNativeFixture()
        defer { fixture.window.close() }
        let anchor = try XCTUnwrap(findAnchors(in: fixture.hosting).first)
        let firstResponder = fixture.window.firstResponder
        anchor.mouseEntered(with: try mouseEvent(.mouseEntered, window: fixture.window))
        XCTAssertNil(anchor.presenter.panel)
        try await Task.sleep(for: .milliseconds(300))
        let panel = try XCTUnwrap(anchor.presenter.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(fixture.window.firstResponder === firstResponder)
        XCTAssertEqual(fixture.model.selectedTabID, "selected")
        XCTAssertNil(anchor.hitTest(NSPoint(x: 5, y: 5)))

        var pane = session("pane", agent: .claude, state: .blocked)
        pane.agentTasks = [task("child", state: .done)]
        fixture.model.snapshot = TabActivitySnapshot(tab: TerminalTab(paneID: pane.id), sessions: [pane])
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(anchor.presenter.panel === panel)
        let content = try XCTUnwrap(panel.contentView as? NSHostingView<TabActivityHoverCard>)
        XCTAssertEqual(content.rootView.snapshot.panes[0].root.state, .blocked)
        XCTAssertEqual(content.rootView.snapshot.panes[0].children[0].state, .done)
        if let path = ProcessInfo.processInfo.environment["TRANO_HOVER_SNAPSHOT"] {
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertTrue(fixture.window.firstResponder === firstResponder)
        XCTAssertEqual(fixture.model.selectedTabID, "selected")
    }

    // Implements: FR-HOVER-2
    @MainActor func testExitCancelsPendingOpenAndDismissesVisiblePanel() async throws {
        let fixture = try makeNativeFixture()
        defer { fixture.window.close() }
        let anchor = try XCTUnwrap(findAnchors(in: fixture.hosting).first)
        anchor.mouseEntered(with: try mouseEvent(.mouseEntered, window: fixture.window))
        anchor.mouseExited(with: try mouseEvent(.mouseExited, window: fixture.window))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(anchor.presenter.panel)

        anchor.mouseEntered(with: try mouseEvent(.mouseEntered, window: fixture.window))
        try await Task.sleep(for: .milliseconds(300))
        let panel = try XCTUnwrap(anchor.presenter.panel)
        anchor.mouseExited(with: try mouseEvent(.mouseExited, window: fixture.window))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(anchor.presenter.panel)
    }

    // Implements: FR-HOVER-2
    @MainActor func testWindowDeactivationAndAnchorRemovalDismissPanel() async throws {
        let fixture = try makeNativeFixture()
        defer { fixture.window.close() }
        let anchor = try XCTUnwrap(findAnchors(in: fixture.hosting).first)
        anchor.mouseEntered(with: try mouseEvent(.mouseEntered, window: fixture.window))
        try await Task.sleep(for: .milliseconds(300))
        let firstPanel = try XCTUnwrap(anchor.presenter.panel)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        XCTAssertFalse(firstPanel.isVisible)
        XCTAssertNil(anchor.presenter.panel)

        anchor.mouseEntered(with: try mouseEvent(.mouseEntered, window: fixture.window))
        try await Task.sleep(for: .milliseconds(300))
        let secondPanel = try XCTUnwrap(anchor.presenter.panel)
        fixture.model.showHoveredTab = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(secondPanel.isVisible)
        XCTAssertNil(anchor.presenter.panel)
        XCTAssertEqual(fixture.model.selectedTabID, "selected")
    }

    // Implements: FR-HOVER-1, FR-HOVER-2
    @MainActor func testLargeChildListKeepsEveryReportedRowInBoundedPanel() async throws {
        let fixture = try makeNativeFixture()
        defer { fixture.window.close() }
        var pane = session("pane", agent: .codex, state: .running)
        pane.agentTasks = (0..<64).map { task("child-\($0)") }
        fixture.model.snapshot = TabActivitySnapshot(tab: TerminalTab(paneID: pane.id), sessions: [pane])
        try await Task.sleep(for: .milliseconds(40))
        let anchor = try XCTUnwrap(findAnchors(in: fixture.hosting).first)
        anchor.mouseEntered(with: try mouseEvent(.mouseEntered, window: fixture.window))
        try await Task.sleep(for: .milliseconds(300))
        let panel = try XCTUnwrap(anchor.presenter.panel)
        let content = try XCTUnwrap(panel.contentView as? NSHostingView<TabActivityHoverCard>)
        XCTAssertEqual(content.rootView.snapshot.panes[0].children.count, 64)
        XCTAssertLessThanOrEqual(panel.frame.height, 460)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    private func session(_ id: String, agent: AgentKind, state: ActivityState, timestamp: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> TerminalSession {
        var result = TerminalSession(id: id, title: "Pane \(id)", cwd: "/tmp", pid: 1)
        result.agent = agent
        result.activity = activity(state, source: "provider-hook", timestamp: timestamp)
        return result
    }

    private func task(_ id: String, parent: String? = nil, state: ActivityState = .running, timestamp: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AgentTask {
        AgentTask(id: id, parentID: parent, name: id, agent: .codex,
                  activity: activity(state, source: "child-hook", timestamp: timestamp), generation: "generation")
    }

    private func activity(_ state: ActivityState, source: String, timestamp: Date) -> Activity {
        var result = Activity()
        result.state = state
        result.source = source
        result.updatedAt = timestamp
        return result
    }

    @MainActor private func makeNativeFixture() throws -> (window: NSWindow, hosting: NSHostingView<HoverTestTabs>, model: HoverTestModel) {
        _ = NSApplication.shared
        let pane = session("pane", agent: .claude, state: .running)
        let model = HoverTestModel(snapshot: TabActivitySnapshot(tab: TerminalTab(paneID: pane.id), sessions: [pane]))
        let window = HoverTestWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let hosting = NSHostingView(rootView: HoverTestTabs(model: model))
        hosting.frame = NSRect(x: 0, y: 320, width: 640, height: 80)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        container.addSubview(hosting)
        container.addSubview(editor)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isKeyWindow, "Hover fixture must own the key window")
        XCTAssertTrue(window.makeFirstResponder(editor))
        hosting.layoutSubtreeIfNeeded()
        for anchor in findAnchors(in: hosting) {
            XCTAssertFalse(anchor.visibleRect.isEmpty, "Hover anchor must have visible tracking bounds: \(anchor.frame)")
        }
        return (window, hosting, model)
    }

    @MainActor private func findAnchors(in view: NSView) -> [TabActivityHoverTrackingView] {
        (view as? TabActivityHoverTrackingView).map { [$0] } ?? view.subviews.flatMap { findAnchors(in: $0) }
    }

    @MainActor private func mouseEvent(_ type: NSEvent.EventType, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: NSPoint(x: 10, y: 350), modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }
}

// SwiftPM's background-only XCTest helper cannot acquire a key window.
@MainActor private final class HoverTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private final class HoverTestModel: ObservableObject {
    @Published var snapshot: TabActivitySnapshot
    @Published var showHoveredTab = true
    @Published var selectedTabID = "selected"
    init(snapshot: TabActivitySnapshot) { self.snapshot = snapshot }
}

private struct HoverTestTabs: View {
    @ObservedObject var model: HoverTestModel
    var body: some View {
        HStack {
            Button("Selected") { model.selectedTabID = "selected" }
            if model.showHoveredTab {
                Button("Hovered") { model.selectedTabID = "hovered" }
                    .modifier(TabActivityHover(snapshot: model.snapshot, placement: .below))
            }
        }.padding(10)
    }
}
