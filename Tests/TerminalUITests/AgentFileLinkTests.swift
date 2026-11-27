import AppKit
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class AgentFileLinkTests: XCTestCase {
    func testRelativeAbsoluteAndLineLinksOpenFromClickedPaneForBothProviders() throws {
        for agent in [AgentKind.claude, .codex] {
            let f = try Fixture(agent: agent); defer { f.close() }
            for link in [f.file.path, "src/한글 문서.md", "./src/한글 문서.md:42", "src/한글 문서.md:42:7"] {
                f.view.requestOpenLink(source: f.view, link: link, params: [:])
            }
            XCTAssertEqual(f.opened.map(\.path), Array(repeating: f.file.path, count: 4))
            XCTAssertNil(f.store.message)
        }
    }

    func testRelativeLinkUsesOriginPaneDirectoryWhileAnotherTabIsFocused() throws {
        let f = try Fixture(); defer { f.close() }
        let otherID = UUID().uuidString.lowercased()
        let other = TerminalSession(id: otherID, title: "Other", cwd: f.root.path, pid: 0, alive: false)
        f.store.sessions.append(other)
        f.store.state.layout.addTab(paneID: otherID)
        XCTAssertEqual(f.store.focusedID, otherID)
        f.view.requestOpenLink(source: f.view, link: "src/한글 문서.md:42", params: [:])
        XCTAssertEqual(f.opened.map(\.path), [f.file.path])
    }

    func testFileURLLineColumnAndFragmentBecomeAnExistingFileURL() throws {
        let f = try Fixture(); defer { f.close() }
        for link in [f.file.absoluteString + ":42:7", f.file.absoluteString + "#L42", f.file.absoluteString + "#L42C7"] {
            f.view.requestOpenLink(source: f.view, link: link, params: [:])
        }
        XCTAssertEqual(f.opened.map(\.path), Array(repeating: f.file.path, count: 3))
        XCTAssertTrue(f.opened.allSatisfy { $0.fragment == nil && $0.isFileURL })
    }

    func testExistingColonFilenameAndLiteralPercentAreNotRewritten() throws {
        let f = try Fixture(); defer { f.close() }
        let files = ["src/literal.md:42", "src/percent%20name.md"].map { f.cwd.appendingPathComponent($0) }
        for file in files {
            try Data("fixture".utf8).write(to: file)
            f.view.requestOpenLink(source: f.view, link: file.path, params: [:])
        }
        XCTAssertEqual(f.opened.map(\.path), files.map(\.path))
    }

    func testOSC8CommandClickUsesActualFileTargetInsteadOfVisibleLabel() throws {
        let f = try Fixture(); defer { f.close() }
        f.view.feed(text: "\u{1b}]8;;" + f.file.path + ":42\u{1b}\\문서 열기\u{1b}]8;;\u{1b}\\")
        let point = NSPoint(x: f.view.cellDimension.width * 0.5, y: f.view.bounds.height - f.view.cellDimension.height * 0.5)
        XCTAssertEqual(f.view.link(atViewPoint: point), f.file.path + ":42")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: f.view.convert(point, to: nil),
                modifierFlags: .command, timestamp: 1, windowNumber: f.window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { f.view.mouseDown(with: event) } else { f.view.mouseUp(with: event) }
        }
        XCTAssertEqual(f.opened.map(\.path), [f.file.path])
    }

    func testRemotePathsNeverOpenAnUnrelatedLocalFile() throws {
        let f = try Fixture(); defer { f.close() }
        f.store.sessions[0].remote = RemoteReference(hostID: "remote", sessionID: "remote-session")
        f.view.requestOpenLink(source: f.view, link: f.file.absoluteString, params: [:])
        f.view.requestOpenLink(source: f.view, link: f.file.path, params: [:])
        f.store.sessions[0].remote = nil
        f.store.sessions[0].host = "remote-host"
        f.view.requestOpenLink(source: f.view, link: f.file.absoluteString, params: [:])
        XCTAssertTrue(f.opened.isEmpty)
    }

    func testMissingFileNeverFallsThroughAsAnApplicationURL() throws {
        let f = try Fixture(); defer { f.close() }
        f.view.requestOpenLink(source: f.view, link: f.cwd.appendingPathComponent("missing.swift").absoluteString + ":42", params: [:])
        XCTAssertTrue(f.opened.isEmpty)
    }

    func testWebPolicyAndOwnerGuardsRemainInForce() throws {
        let f = try Fixture(); defer { f.close() }
        let web = try XCTUnwrap(URL(string: "https://example.com/source:42"))
        f.view.requestOpenLink(source: f.view, link: web.absoluteString, params: [:])
        XCTAssertEqual(f.opened, [web])
        f.store.terminalPreferences.applicationLinks = .never
        f.view.requestOpenLink(source: f.view, link: f.file.path, params: [:])
        f.store.terminalPreferences.applicationLinks = .always
        f.store.terminalViews.removeAll()
        f.view.requestOpenLink(source: f.view, link: f.file.path, params: [:])
        XCTAssertEqual(f.opened, [web])
    }

    @MainActor private final class Fixture {
        let root: URL
        let cwd: URL
        let file: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let view: TranoView
        let bridge: TerminalBridge
        let window: NSWindow
        var opened: [URL] = []
        init(agent: AgentKind = .claude) throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: "/tmp/trano-file-link-" + UUID().uuidString.prefix(8))
            root = directory
            cwd = directory.appendingPathComponent("project")
            file = cwd.appendingPathComponent("src/한글 문서.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            runtime = try TerminalRuntime(root: directory.appendingPathComponent("runtime"))
            store = AppStore(runtime: runtime, startServices: false)
            let id = UUID().uuidString.lowercased()
            var pane = TerminalSession(id: id, title: "Fixture", cwd: cwd.path, pid: 0, alive: false)
            pane.agent = agent
            store.sessions = [pane]
            store.state.layout.addTab(paneID: id)
            store.terminalPreferences.applicationLinks = .always
            view = TranoView(frame: NSRect(x: 0, y: 0, width: 1000, height: 260))
            view.frameDriver.invalidate()
            view.paneID = id; view.store = store
            store.terminalViews[id] = view
            bridge = TerminalBridge(view: view); view.terminalDelegate = bridge
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = view; window.orderFrontRegardless()
            view.terminalInteractionOpener = { [weak self] in self?.opened.append($0) }
            XCTAssertNotNil(view.interactionOwner())
        }
        func close() {
            view.invalidateTerminalInteractions(); view.terminalDelegate = nil
            store.terminalViews.removeAll(); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
